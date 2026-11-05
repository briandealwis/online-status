import Foundation

/// Connectivity quality, ordered from worst to best.
public enum ConnectivityLevel: Int, Comparable, CaseIterable, Sendable {
    case offline = 0
    case poor = 1
    case mixed = 2
    case good = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var name: String {
        switch self {
        case .offline: return "No connectivity"
        case .poor: return "Poor"
        case .mixed: return "Mixed"
        case .good: return "Good"
        }
    }

    /// The next better level, if any.
    var better: ConnectivityLevel? { ConnectivityLevel(rawValue: rawValue + 1) }
}

/// What the menu bar shows.
public enum DisplayStatus: Equatable, Sendable {
    /// Not enough samples yet (at startup or after the network changed).
    case measuring
    case level(ConnectivityLevel)
    /// A captive portal intercepted the probe (counts as offline).
    case captivePortal

    public var name: String {
        switch self {
        case .measuring: return "Measuring…"
        case .level(let level): return level.name
        case .captivePortal: return "Wi-Fi login required"
        }
    }

    /// The level used for hysteresis; `nil` while measuring.
    public var level: ConnectivityLevel? {
        switch self {
        case .measuring: return nil
        case .level(let level): return level
        case .captivePortal: return .offline
        }
    }
}

/// Thresholds and timings that decide the status. All times are in seconds.
public struct EvaluatorConfiguration: Equatable, Sendable {
    /// Samples older than this are ignored.
    public var window: TimeInterval = 60
    /// Number of samples needed before leaving `.measuring` (unless failures are seen first).
    public var minimumSamples: Int = 2
    /// Good needs a median RTT below this...
    public var goodMedianRTT: TimeInterval = 0.150
    /// ...and a 90th percentile RTT below this...
    public var goodP90RTT: TimeInterval = 0.400
    /// ...and loss no greater than this.
    public var goodMaxLoss: Double = 0
    /// Median RTT above this is poor.
    public var poorMedianRTT: TimeInterval = 0.500
    /// Loss above this is poor.
    public var mixedMaxLoss: Double = 0.20
    /// This many failures in a row means offline.
    public var offlineConsecutiveFailures: Int = 2
    /// To climb one level, the raw level must stay better for at least this long...
    public var recoveryDuration: TimeInterval = 30
    /// ...and over at least this many consecutive samples.
    public var recoverySamples: Int = 3

    public init() {}
}

/// Turns samples into a display status, dropping quickly and recovering slowly.
///
/// * The *raw* level is computed from the samples in the sliding window.
/// * When the raw level is worse than what is displayed, the display drops at once.
/// * When it is better, the display climbs one level at a time, and only after the raw
///   level has stayed better for `recoveryDuration` and `recoverySamples` samples.
///   Leaving offline always goes to poor first.
public struct StatusEvaluator: Sendable {
    public var configuration: EvaluatorConfiguration
    public private(set) var status: DisplayStatus = .measuring

    private var betterSince: Date?
    private var betterCount = 0

    public init(configuration: EvaluatorConfiguration = EvaluatorConfiguration()) {
        self.configuration = configuration
    }

    /// Forget the current status, e.g. after the network changed.
    public mutating func reset() {
        status = .measuring
        betterSince = nil
        betterCount = 0
    }

    /// The level suggested by the samples alone, without hysteresis.
    /// Returns `nil` when there isn't enough data yet.
    public func rawLevel(_ samples: some Collection<Sample>, now: Date) -> ConnectivityLevel? {
        let windowStart = now.addingTimeInterval(-configuration.window)
        let recent = samples.filter { $0.date >= windowStart }
        guard let last = recent.last else { return nil }

        if last.failure == .noPath || last.failure == .captivePortal { return .offline }

        let trailingFailures = recent.reversed().prefix(while: { !$0.isSuccess }).count
        if trailingFailures >= configuration.offlineConsecutiveFailures { return .offline }

        let summary = SampleSummary(recent)
        if summary.failureCount == 0 && summary.count < configuration.minimumSamples { return nil }
        guard let median = summary.medianRTT, let p90 = summary.p90RTT else { return .poor }

        if summary.loss <= configuration.goodMaxLoss
            && median < configuration.goodMedianRTT
            && p90 < configuration.goodP90RTT {
            return .good
        }
        if summary.loss <= configuration.mixedMaxLoss && median <= configuration.poorMedianRTT {
            return .mixed
        }
        return .poor
    }

    /// Re-evaluate after a new sample. `samples` must be in chronological order.
    @discardableResult
    public mutating func evaluate(_ samples: some Collection<Sample>, now: Date) -> DisplayStatus {
        let portal = samples.last?.failure == .captivePortal
        guard let raw = rawLevel(samples, now: now) else {
            // Not enough data; keep whatever we were showing.
            return status
        }

        guard let shown = status.level else {
            // First verdict after measuring: show it directly.
            set(raw, portal: portal)
            return status
        }

        if raw <= shown {
            set(raw, portal: portal)
            return status
        }

        // Raw level is better than what's shown.
        if shown == .offline {
            set(.poor, portal: false)
            return status
        }
        if betterSince == nil { betterSince = now }
        betterCount += 1
        if let since = betterSince,
           now.timeIntervalSince(since) >= configuration.recoveryDuration,
           betterCount >= configuration.recoverySamples,
           let next = shown.better {
            set(next, portal: false)
        }
        return status
    }

    private mutating func set(_ level: ConnectivityLevel, portal: Bool) {
        status = portal && level == .offline ? .captivePortal : .level(level)
        betterSince = nil
        betterCount = 0
    }
}
