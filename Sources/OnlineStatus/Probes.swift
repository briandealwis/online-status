import Darwin
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
    private let url: URL?
    private let expectation: HTTPExpectation
    private let session: URLSession

    init(urlString: String, expectation: HTTPExpectation, timeout: TimeInterval) {
        self.url = URL(string: urlString)
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
        guard let url else { return .failure(at: start, .error("Invalid URL")) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let clock = ContinuousClock()
        let began = clock.now
        do {
            let (_, response) = try await session.data(for: request)
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
struct PingProbe: Probe {
    let host: String
    let timeout: TimeInterval

    private static let identifier = UInt16.random(in: 1...UInt16.max)
    private static let sequence = SequenceCounter()

    func run() async -> Sample {
        let start = Date()
        let sequence = PingProbe.sequence.next()
        let host = self.host
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = PingProbe.ping(host: host, identifier: PingProbe.identifier,
                                            sequence: sequence, timeout: timeout)
                switch result {
                case .success(let rtt): continuation.resume(returning: .success(at: start, rtt: rtt))
                case .failure(let reason): continuation.resume(returning: .failure(at: start, reason))
                }
            }
        }
    }

    private enum Outcome {
        case success(TimeInterval)
        case failure(FailureReason)
    }

    private static func ping(host: String, identifier: UInt16, sequence: UInt16, timeout: TimeInterval) -> Outcome {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(Int64(timeout * 1000))

        guard var address = resolveIPv4(host) else {
            return .failure(.error("Cannot resolve \(host)"))
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return .failure(.error("socket: \(String(cString: strerror(errno)))")) }
        defer { close(fd) }

        let payload = Array("online-status!".utf8)
        let packet = ICMPEcho.request(identifier: identifier, sequence: sequence, payload: payload)
        let began = clock.now
        let sent = packet.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buffer.baseAddress, buffer.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else {
            return .failure(.error("send: \(String(cString: strerror(errno)))"))
        }

        let capacity = 1500
        var buffer = [UInt8](repeating: 0, count: capacity)
        while true {
            let remaining = (deadline - clock.now).seconds
            if remaining <= 0 { return .failure(.timeout) }
            var tv = timeval(tv_sec: Int(remaining),
                             tv_usec: __darwin_suseconds_t((remaining - Double(Int(remaining))) * 1_000_000))
            if tv.tv_sec == 0 && tv.tv_usec == 0 { tv.tv_usec = 1000 }
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            let count = recv(fd, &buffer, capacity, 0)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return .failure(.timeout) }
                return .failure(.error("recv: \(String(cString: strerror(errno)))"))
            }
            if let reply = ICMPEcho.parseReply(Array(buffer[0..<count])),
               reply.identifier == identifier, reply.sequence == sequence {
                return .success((clock.now - began).seconds)
            }
            // Some other packet (e.g. a late reply to an earlier probe); keep waiting.
        }
    }

    private static func resolveIPv4(_ host: String) -> sockaddr_in? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &results) == 0, let first = results else { return nil }
        defer { freeaddrinfo(results) }
        guard let address = first.pointee.ai_addr, first.pointee.ai_family == AF_INET else { return nil }
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }
}

/// Thread-safe wrapping 16-bit counter for ICMP sequence numbers.
final class SequenceCounter: @unchecked Sendable {
    private var value: UInt16 = 0
    private let lock = NSLock()

    func next() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}
