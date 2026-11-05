import Foundation

/// Summary statistics over a set of samples.
public struct SampleSummary: Equatable, Sendable {
    public var count: Int
    public var successCount: Int
    public var medianRTT: TimeInterval?
    public var p90RTT: TimeInterval?
    public var minRTT: TimeInterval?
    public var maxRTT: TimeInterval?
    public var last: Sample?

    public var failureCount: Int { count - successCount }

    /// Fraction of probes that failed, from 0 to 1. Zero when there are no samples.
    public var loss: Double {
        count == 0 ? 0 : Double(failureCount) / Double(count)
    }

    public init(_ samples: some Collection<Sample>) {
        count = samples.count
        let rtts = samples.compactMap(\.rtt).sorted()
        successCount = rtts.count
        medianRTT = SampleSummary.percentile(0.5, ofSorted: rtts)
        p90RTT = SampleSummary.percentile(0.9, ofSorted: rtts)
        minRTT = rtts.first
        maxRTT = rtts.last
        last = samples.max(by: { $0.date < $1.date })
    }

    /// Percentile using linear interpolation between closest ranks.
    public static func percentile(_ p: Double, ofSorted values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values[0] }
        let rank = min(max(p, 0), 1) * Double(values.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = min(lower + 1, values.count - 1)
        let fraction = rank - Double(lower)
        return values[lower] + (values[upper] - values[lower]) * fraction
    }
}

/// Keeps samples for a limited time span.
public struct SampleHistory: Sendable {
    public private(set) var samples: [Sample] = []
    /// How long samples are kept, in seconds.
    public var retention: TimeInterval

    public init(retention: TimeInterval) {
        self.retention = retention
    }

    public mutating func append(_ sample: Sample) {
        samples.append(sample)
        let cutoff = sample.date.addingTimeInterval(-retention)
        if let firstKept = samples.firstIndex(where: { $0.date >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
    }

    /// Samples taken at or after `date`.
    public func samples(since date: Date) -> ArraySlice<Sample> {
        let start = samples.firstIndex(where: { $0.date >= date }) ?? samples.endIndex
        return samples[start...]
    }

    public mutating func removeAll() {
        samples.removeAll()
    }
}
