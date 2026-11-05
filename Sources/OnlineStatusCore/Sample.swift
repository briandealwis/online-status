import Foundation

/// Why a probe failed.
public enum FailureReason: Equatable, Sendable {
    /// No response within the configured timeout.
    case timeout
    /// The operating system reports no usable network path.
    case noPath
    /// An HTTP response arrived that looks like a captive portal (login page or redirect).
    case captivePortal
    /// An HTTP response with an unexpected status code.
    case unexpectedStatus(Int)
    /// Any other error (DNS failure, connection refused, unreachable, ...).
    case error(String)

    public var description: String {
        switch self {
        case .timeout: return "Timed out"
        case .noPath: return "No network"
        case .captivePortal: return "Wi-Fi login required"
        case .unexpectedStatus(let code): return "HTTP \(code)"
        case .error(let message): return message
        }
    }
}

/// The result of a single connectivity probe.
public struct Sample: Equatable, Sendable {
    /// When the probe started.
    public var date: Date
    /// Round-trip time in seconds; `nil` when the probe failed.
    public var rtt: TimeInterval?
    /// `nil` when the probe succeeded.
    public var failure: FailureReason?

    public init(date: Date, rtt: TimeInterval?, failure: FailureReason? = nil) {
        self.date = date
        self.rtt = failure == nil ? rtt : nil
        self.failure = failure
    }

    public static func success(at date: Date, rtt: TimeInterval) -> Sample {
        Sample(date: date, rtt: rtt)
    }

    public static func failure(at date: Date, _ reason: FailureReason) -> Sample {
        Sample(date: date, rtt: nil, failure: reason)
    }

    public var isSuccess: Bool { failure == nil }
}

extension Duration {
    /// The duration expressed in (fractional) seconds.
    public var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
