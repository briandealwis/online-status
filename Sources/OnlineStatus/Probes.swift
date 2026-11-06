import Darwin
import dnssd
import Foundation
import OnlineStatusCore

/// Something that checks connectivity once.
protocol Probe: Sendable {
    func run() async -> Sample
}

func makeProbe(for settings: MonitorSettings) -> any Probe {
    switch settings.mode {
    case .ping:
        return PingProbe(host: settings.pingHost, timeout: settings.timeout)
    case .http:
        return HTTPProbe(urlString: settings.url, expectation: settings.httpExpectation, timeout: settings.timeout)
    }
}

// MARK: - HTTP

/// Fetches a URL and checks the status code. Redirects are not followed so that
/// captive portals can be recognised.
final class HTTPProbe: Probe {
    private let url: Result<URL, MonitorSettings.URLProblem>
    private let expectation: HTTPExpectation
    private let session: URLSession

    init(urlString: String, expectation: HTTPExpectation, timeout: TimeInterval) {
        self.url = MonitorSettings.validateURL(urlString)
        self.expectation = expectation
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func run() async -> Sample {
        let start = Date()
        let url: URL
        switch self.url {
        case .success(let valid): url = valid
        case .failure(let problem): return .failure(at: start, .error(problem.description))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let clock = ContinuousClock()
        let began = clock.now
        do {
            // Returns once the response headers arrive. The body is never read: cancelling
            // the task discards it, so a large or endless body costs nothing.
            let (body, response) = try await session.bytes(for: request)
            body.task.cancel()
            let elapsed = (clock.now - began).seconds
            guard let http = response as? HTTPURLResponse else {
                return .failure(at: start, .error("Not an HTTP response"))
            }
            if let failure = expectation.failure(forStatus: http.statusCode) {
                return .failure(at: start, failure)
            }
            return .success(at: start, rtt: elapsed)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return .failure(at: start, .timeout)
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .failure(at: start, .error(error.localizedDescription))
            case .appTransportSecurityRequiresSecureConnection:
                return .failure(at: start, .error(MonitorSettings.URLProblem.plainHTTPNotAllowed.description))
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                // Captive portals often intercept HTTPS with their own certificate.
                return .failure(at: start, .captivePortal)
            default:
                return .failure(at: start, .error(error.localizedDescription))
            }
        } catch {
            return .failure(at: start, .error(error.localizedDescription))
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Ping

/// Sends one ICMP echo request using an unprivileged datagram socket, which works
/// without root and inside the App Sandbox. IPv4 only.
///
/// Nothing blocks a thread: DNS uses `DNSServiceGetAddrInfo` and the socket is
/// non-blocking with a dispatch read source. Cancelling the calling task (for example
/// when the network changes) stops DNS, closes the socket and returns at once.
struct PingProbe: Probe {
    let host: String
    let timeout: TimeInterval

    func run() async -> Sample {
        let start = Date()
        let operation = PingOperation(host: host, timeout: timeout)
        switch await operation.run() {
        case .success(let rtt): return .success(at: start, rtt: rtt)
        case .failure(let reason): return .failure(at: start, reason)
        }
    }
}

private enum PingOutcome {
    case success(TimeInterval)
    case failure(FailureReason)
}

/// One ping. All state is confined to `queue`.
private final class PingOperation: @unchecked Sendable {
    private let host: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "OnlineStatus.ping")
    private let clock = ContinuousClock()

    // Random per probe, so that replies can't easily be forged or confused with others.
    private let identifier = UInt16.random(in: 0...UInt16.max)
    private let sequence = UInt16.random(in: 0...UInt16.max)
    private let payload = (0..<16).map { _ in UInt8.random(in: 0...UInt8.max) }

    private var continuation: CheckedContinuation<PingOutcome, Never>?
    private var result: PingOutcome?
    private var dnsRef: DNSServiceRef?
    private var timer: DispatchSourceTimer?
    private var readSource: DispatchSourceRead?
    private var socketFD: Int32 = -1
    private var target = in_addr()
    private var sentAt: ContinuousClock.Instant?

    init(host: String, timeout: TimeInterval) {
        self.host = host
        self.timeout = timeout
    }

    func run() async -> PingOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            queue.async { self.finish(.failure(.error("Cancelled"))) }
        }
    }

    // MARK: Steps (on queue)

    private func start(_ continuation: CheckedContinuation<PingOutcome, Never>) {
        if let result {
            // Cancelled before we started.
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation

        // The timeout covers DNS as well: a lookup that stalls means the network is poor.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(.failure(.timeout)) }
        timer.resume()
        self.timer = timer

        var literal = in_addr()
        if inet_pton(AF_INET, host, &literal) == 1 {
            send(to: literal)
        } else {
            resolve()
        }
    }

    private func resolve() {
        let callback: DNSServiceGetAddrInfoReply = { _, _, _, error, _, address, _, context in
            guard let context else { return }
            let operation = Unmanaged<PingOperation>.fromOpaque(context).takeUnretainedValue()
            operation.resolved(error: error, address: address)
        }
        var ref: DNSServiceRef?
        let error = DNSServiceGetAddrInfo(
            &ref, 0, 0, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host, callback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            finish(.failure(.error("Cannot resolve \(host)")))
            return
        }
        dnsRef = ref
        // Callbacks arrive on our queue; the reference is deallocated on it too.
        DNSServiceSetDispatchQueue(ref, queue)
    }

    private func resolved(error: DNSServiceErrorType, address: UnsafePointer<sockaddr>?) {
        guard result == nil else { return }
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            finish(.failure(.error("Cannot resolve \(host)")))
            return
        }
        guard let address, address.pointee.sa_family == sa_family_t(AF_INET) else { return }
        let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        stopDNS()
        send(to: ipv4.sin_addr)
    }

    private func send(to address: in_addr) {
        target = address
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else {
            finish(.failure(.error("socket: \(String(cString: strerror(errno)))")))
            return
        }
        socketFD = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        // Connecting limits the socket to replies from the target and reports ICMP errors.
        var peer = sockaddr_in()
        peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_addr = address
        let connected = withUnsafePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            finish(.failure(.error(socketError("connect"))))
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.receive() }
        source.setCancelHandler { close(fd) }
        readSource = source
        source.resume()

        let packet = ICMPEcho.request(identifier: identifier, sequence: sequence, payload: payload)
        sentAt = clock.now
        let sent = packet.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == packet.count else {
            finish(.failure(.error(socketError("send"))))
            return
        }
    }

    private func receive() {
        let capacity = 1500
        var buffer = [UInt8](repeating: 0, count: capacity)
        while result == nil {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socketFD, &buffer, capacity, 0, $0, &fromLength)
                }
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                finish(.failure(.error(socketError("recv"))))
                return
            }
            guard from.sin_addr.s_addr == target.s_addr,
                  let reply = ICMPEcho.parseReply(Array(buffer[0..<count])),
                  ICMPEcho.reply(reply, matches: identifier, sequence: sequence, payload: payload,
                                 expectedSource: UInt32(bigEndian: target.s_addr)),
                  let sentAt
            else { continue } // Not our reply; keep waiting.
            finish(.success((clock.now - sentAt).seconds))
        }
    }

    private func socketError(_ call: String) -> String {
        if errno == EPERM { return "Ping blocked by the App Sandbox" }
        return "\(call): \(String(cString: strerror(errno)))"
    }

    private func stopDNS() {
        if let dnsRef {
            DNSServiceRefDeallocate(dnsRef)
            self.dnsRef = nil
        }
    }

    /// Deliver the outcome once and release everything.
    private func finish(_ outcome: PingOutcome) {
        guard result == nil else { return }
        result = outcome
        stopDNS()
        timer?.cancel()
        timer = nil
        if let readSource {
            readSource.cancel() // closes the socket
            self.readSource = nil
        } else if socketFD >= 0 {
            close(socketFD)
        }
        socketFD = -1
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: outcome)
        }
    }
}
