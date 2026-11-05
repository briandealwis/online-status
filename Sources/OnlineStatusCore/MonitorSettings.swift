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
        normalize()
    }

    /// Keeps values within sensible bounds.
    public mutating func normalize() {
        interval = min(max(interval, 1), 3600)
        // A probe must finish before the next one is due.
        timeout = min(max(timeout, 0.5), interval)
        poorLatencyMs = max(poorLatencyMs, goodLatencyMs)
        recoverySeconds = max(recoverySeconds, 0)
    }

    /// A short description of what is being probed, e.g. "Ping 8.8.8.8".
    public var targetDescription: String {
        switch mode {
        case .ping: return "Ping \(pingHost)"
        case .http: return "Fetch \(url)"
        }
    }

    /// Evaluator thresholds derived from these settings.
    public var evaluatorConfiguration: EvaluatorConfiguration {
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

    private static func positive(_ value: Double) -> Double? {
        value > 0 ? value : nil
    }
}
