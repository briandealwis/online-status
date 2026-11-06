import Foundation

/// User-configurable settings, stored in `UserDefaults`.
public struct MonitorSettings: Equatable, Sendable {
    public enum Key {
        public static let mode = "mode"
        public static let pingHost = "pingHost"
        public static let url = "url"
        public static let httpExpectation = "httpExpectation"
        public static let interval = "interval"
        public static let timeout = "timeout"
        public static let goodLatencyMs = "goodLatencyMs"
        public static let poorLatencyMs = "poorLatencyMs"
        public static let recoverySeconds = "recoverySeconds"
        public static let tetheredBackoff = "tetheredBackoff"
        public static let tetheredInterval = "tetheredInterval"
    }

    public static let defaultPingHost = "8.8.8.8"
    public static let defaultURL = "https://connectivitycheck.gstatic.com/generate_204"

    public static let defaults: [String: Any] = [
        Key.mode: ProbeMode.ping.rawValue,
        Key.pingHost: defaultPingHost,
        Key.url: defaultURL,
        Key.httpExpectation: HTTPExpectation.noContent.rawValue,
        Key.interval: 10.0,
        Key.timeout: 3.0,
        Key.goodLatencyMs: 150.0,
        Key.poorLatencyMs: 500.0,
        Key.recoverySeconds: 30.0,
        Key.tetheredBackoff: true,
        Key.tetheredInterval: 30.0,
    ]

    public var mode: ProbeMode = .ping
    public var pingHost: String = defaultPingHost
    public var url: String = defaultURL
    public var httpExpectation: HTTPExpectation = .noContent
    /// Seconds between the start of one probe and the next.
    public var interval: TimeInterval = 10
    /// Seconds before a probe counts as failed.
    public var timeout: TimeInterval = 3
    public var goodLatencyMs: Double = 150
    public var poorLatencyMs: Double = 500
    public var recoverySeconds: TimeInterval = 30
    /// Probe less often on expensive networks (personal hotspot, iPhone tethering) or in Low Data Mode.
    public var tetheredBackoff = true
    /// Seconds between probes when backing off. Never shorter than `interval`.
    public var tetheredInterval: TimeInterval = 30

    public init() {}

    public init(defaults store: UserDefaults) {
        mode = ProbeMode(rawValue: store.string(forKey: Key.mode) ?? "") ?? .ping
        pingHost = Self.nonEmpty(store.string(forKey: Key.pingHost)) ?? Self.defaultPingHost
        url = Self.nonEmpty(store.string(forKey: Key.url)) ?? Self.defaultURL
        httpExpectation = HTTPExpectation(rawValue: store.string(forKey: Key.httpExpectation) ?? "") ?? .noContent
        interval = Self.positive(store.double(forKey: Key.interval)) ?? 10
        timeout = Self.positive(store.double(forKey: Key.timeout)) ?? 3
        goodLatencyMs = Self.positive(store.double(forKey: Key.goodLatencyMs)) ?? 150
        poorLatencyMs = Self.positive(store.double(forKey: Key.poorLatencyMs)) ?? 500
        recoverySeconds = Self.positive(store.double(forKey: Key.recoverySeconds)) ?? 30
        tetheredBackoff = store.object(forKey: Key.tetheredBackoff) as? Bool ?? true
        tetheredInterval = Self.positive(store.double(forKey: Key.tetheredInterval)) ?? 30
        normalize()
    }

    /// Upper bounds for user-editable values.
    public enum Limit {
        public static let interval: TimeInterval = 3600
        public static let timeout: TimeInterval = 60
        public static let latencyMs: Double = 60_000
        public static let recoverySeconds: TimeInterval = 3600
        /// Longest DNS name.
        public static let hostLength = 253
        public static let urlLength = 2048
    }

    /// Keeps every value within sensible lower and upper bounds.
    public mutating func normalize() {
        interval = Self.clamp(interval, 1, Limit.interval)
        tetheredInterval = Self.clamp(tetheredInterval, interval, Limit.interval)
        // A probe must finish before the next one is due.
        timeout = Self.clamp(timeout, 0.5, min(interval, Limit.timeout))
        goodLatencyMs = Self.clamp(goodLatencyMs, 1, Limit.latencyMs)
        poorLatencyMs = Self.clamp(poorLatencyMs, goodLatencyMs, Limit.latencyMs)
        recoverySeconds = Self.clamp(recoverySeconds, 0, Limit.recoverySeconds)
        if pingHost.count > Limit.hostLength { pingHost = Self.defaultPingHost }
        if url.count > Limit.urlLength { url = Self.defaultURL }
    }

    /// Hosts that may be fetched over plain `http://`. App Transport Security blocks plain
    /// HTTP to every other host. Keep in sync with `NSExceptionDomains` in `App/Info.plist`.
    public static let plainHTTPHosts = [
        "captive.apple.com",
        "connectivitycheck.gstatic.com",
        "clients3.google.com",
        "detectportal.firefox.com",
        "www.msftconnecttest.com",
    ]

    public enum URLProblem: Error, Equatable, Sendable {
        case invalid
        case unsupportedScheme
        case plainHTTPNotAllowed

        public var description: String {
            switch self {
            case .invalid:
                return "Not a valid URL"
            case .unsupportedScheme:
                return "The URL must start with http:// or https://"
            case .plainHTTPNotAllowed:
                return "Plain http:// is only allowed for "
                    + MonitorSettings.plainHTTPHosts.joined(separator: ", ") + ". Use https://"
            }
        }
    }

    /// Checks that `string` is an http(s) URL with a host that the app may fetch.
    public static func validateURL(_ string: String) -> Result<URL, URLProblem> {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= Limit.urlLength,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased()
        else { return .failure(.invalid) }
        guard scheme == "http" || scheme == "https" else { return .failure(.unsupportedScheme) }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .failure(.invalid) }
        if scheme == "http" && !plainHTTPHosts.contains(host) {
            return .failure(.plainHTTPNotAllowed)
        }
        return .success(url)
    }

    /// A short description of what is being probed, e.g. "Ping 8.8.8.8".
    public var targetDescription: String {
        switch mode {
        case .ping: return "Ping \(pingHost)"
        case .http: return "Fetch \(url)"
        }
    }

    /// Seconds between probes, given whether the current network is expensive or constrained.
    public func probeInterval(onExpensiveNetwork expensive: Bool) -> TimeInterval {
        expensive && tetheredBackoff ? tetheredInterval : interval
    }

    /// E.g. "Ping 8.8.8.8, every 30 s (tethered)".
    public func scheduleDescription(onExpensiveNetwork expensive: Bool) -> String {
        let seconds = Int(probeInterval(onExpensiveNetwork: expensive))
        let suffix = expensive && tetheredBackoff ? " (tethered)" : ""
        return "\(targetDescription), every \(seconds) s\(suffix)"
    }

    /// Evaluator thresholds derived from these settings for a given probe interval.
    public func makeEvaluatorConfiguration(interval: TimeInterval) -> EvaluatorConfiguration {
        var config = EvaluatorConfiguration()
        // Look at about six samples, and never less than a minute.
        config.window = max(60, interval * 6)
        config.goodMedianRTT = goodLatencyMs / 1000
        // Allow the occasional slow response while still "good".
        config.goodP90RTT = goodLatencyMs * 2.5 / 1000
        config.poorMedianRTT = poorLatencyMs / 1000
        config.recoveryDuration = recoverySeconds
        return config
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), max(lower, upper))
    }

    private static func positive(_ value: Double) -> Double? {
        value > 0 ? value : nil
    }
}
