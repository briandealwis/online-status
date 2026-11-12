import Foundation

/// A place on Earth, as reported by Location Services.
public struct Coordinate: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Horizontal accuracy in metres.
    public var accuracy: Double

    public init(latitude: Double, longitude: Double, accuracy: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
    }

    /// Great-circle distance in metres (haversine).
    public func distance(to other: Coordinate) -> Double {
        let radius = 6_371_000.0
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(a)))
    }
}

/// Where a sample was taken.
public struct LogContext: Equatable, Sendable {
    /// E.g. "Wi-Fi: TrainNet", "Hotspot: Brian's iPhone", "Ethernet".
    public var network: String
    public var location: Coordinate?

    public init(network: String, location: Coordinate?) {
        self.network = network
        self.location = location
    }
}

/// A stretch of time at one status on one network in one area: one row of the log.
public struct LogSegment: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var status: DisplayStatus
    public var network: String
    /// Location at the start of the stretch (or the first one known during it).
    public var location: Coordinate?
    public var probes = 0
    public var failures = 0
    public var rtts: [TimeInterval] = []

    public var loss: Double { probes == 0 ? 0 : Double(failures) / Double(probes) }
    public var medianRTT: TimeInterval? { SampleSummary.percentile(0.5, ofSorted: rtts.sorted()) }
}

/// Coalesces samples into segments, so the log grows by a row per change, not per probe.
///
/// A segment ends when the status changes, the network changes, the Mac moves more than
/// `maxDistance` from where the segment began, the segment reaches `maxDuration`, or
/// `close(at:)` is called (sleep, quit, logging turned off). While the status is
/// "measuring" nothing is recorded.
public struct SegmentRecorder: Sendable {
    /// Split long stretches so each row has a meaningful location and little is lost on a crash.
    public var maxDuration: TimeInterval = 15 * 60
    /// Split when the Mac has moved this far (metres), e.g. along a train line.
    public var maxDistance: Double = 1000
    public private(set) var current: LogSegment?

    public init() {}

    /// Adds a sample. Returns the segment it completed, if any.
    public mutating func record(_ sample: Sample, status: DisplayStatus, context: LogContext) -> LogSegment? {
        guard status != .measuring else { return close(at: sample.date) }

        var finished: LogSegment?
        if var segment = current {
            if segment.location == nil, let location = context.location {
                segment.location = location
                current = segment
            }
            // The Wi-Fi name can be missing for a moment (e.g. until Location Services permission
            // takes effect): "Wi-Fi" and "Wi-Fi: Name" are the same network.
            if segment.network != context.network,
               Self.sameNetwork(segment.network, context.network),
               Self.networkName(context.network) != nil {
                segment.network = context.network
                current = segment
            }
            let moved = segment.location.flatMap { start in context.location.map { start.distance(to: $0) } } ?? 0
            if segment.status != status
                || !Self.sameNetwork(segment.network, context.network)
                || sample.date.timeIntervalSince(segment.start) >= maxDuration
                || moved > maxDistance {
                finished = close(at: sample.date)
            }
        }

        var segment = current ?? LogSegment(start: sample.date, end: sample.date, status: status,
                                            network: context.network, location: context.location)
        segment.probes += 1
        if let rtt = sample.rtt {
            segment.rtts.append(rtt)
        } else {
            segment.failures += 1
        }
        segment.end = max(segment.end, sample.date)
        current = segment
        return finished
    }

    /// True if two network descriptions can be the same network: equal, or the same kind
    /// ("Wi-Fi", "Hotspot", ...) where at least one has no name.
    public static func sameNetwork(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        return networkKind(a) == networkKind(b) && (networkName(a) == nil || networkName(b) == nil)
    }

    /// "Wi-Fi" for "Wi-Fi: TrainNet".
    static func networkKind(_ network: String) -> Substring {
        network.range(of: ": ").map { network[..<$0.lowerBound] } ?? network[...]
    }

    /// "TrainNet" for "Wi-Fi: TrainNet"; nil for "Wi-Fi".
    static func networkName(_ network: String) -> Substring? {
        network.range(of: ": ").map { network[$0.upperBound...] }
    }

    /// Ends the current segment at `date`. Returns it, if there was one.
    public mutating func close(at date: Date) -> LogSegment? {
        guard var segment = current else { return nil }
        segment.end = max(segment.end, date)
        current = nil
        return segment
    }
}

extension DisplayStatus {
    /// Stable name used in the log file.
    public var logName: String {
        switch self {
        case .measuring: return "measuring"
        case .captivePortal: return "captive-portal"
        case .level(let level):
            switch level {
            case .good: return "good"
            case .mixed: return "mixed"
            case .poor: return "poor"
            case .offline: return "offline"
            }
        }
    }
}

/// The CSV log format.
public enum ConnectivityLogCSV {
    public static let header =
        "start,end,duration_s,status,network,latitude,longitude,accuracy_m,probes,failed,loss_pct,median_ms"

    /// Local time, "2026-11-12 08:41:44", which Numbers and Excel recognise as a date.
    public static func makeDateFormatter(timeZone: TimeZone = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    public static func row(_ segment: LogSegment, formatter: DateFormatter) -> String {
        let location = segment.location
        let fields: [String] = [
            formatter.string(from: segment.start),
            formatter.string(from: segment.end),
            String(Int(segment.end.timeIntervalSince(segment.start).rounded())),
            segment.status.logName,
            text(segment.network),
            location.map { String(format: "%.5f", $0.latitude) } ?? "",
            location.map { String(format: "%.5f", $0.longitude) } ?? "",
            location.map { String(format: "%.0f", $0.accuracy) } ?? "",
            String(segment.probes),
            String(segment.failures),
            String(format: "%.1f", segment.loss * 100),
            segment.medianRTT.map { String(format: "%.1f", $0 * 1000) } ?? "",
        ]
        return fields.joined(separator: ",")
    }

    /// Quotes a free-text field (such as a Wi-Fi name) for CSV. Text that a spreadsheet would
    /// treat as a formula is prefixed with an apostrophe, so a network named "=HYPERLINK(...)"
    /// can't run anything when the log is opened.
    public static func text(_ value: String) -> String {
        var value = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if let first = value.first, "=+-@\t".contains(first) {
            value = "'" + value
        }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "'" || $0 == " " }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Removes rows that started before `cutoff`. Keeps the header and any row it can't parse.
    public static func prune(_ contents: String, before cutoff: Date, formatter: DateFormatter) -> String {
        var kept: [Substring] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            if line == header[...] {
                kept.append(line)
                continue
            }
            let start = line.prefix(while: { $0 != "," })
            if let date = formatter.date(from: String(start)), date < cutoff { continue }
            kept.append(line)
        }
        if kept.first != header[...] { kept.insert(header[...], at: 0) }
        return kept.joined(separator: "\n") + "\n"
    }
}
