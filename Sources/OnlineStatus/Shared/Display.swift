import OnlineStatusCore
import SwiftUI

extension DisplayStatus {
    /// Traffic-light colour, for shading and dots.
    var color: Color {
        switch self {
        case .measuring: return .gray
        case .captivePortal: return .black
        case .level(let level):
            switch level {
            case .good: return .green
            case .mixed: return .yellow
            case .poor: return .red
            case .offline: return .black
            }
        }
    }

    /// Shown instead of a circle.
    var emoji: String? {
        self == .captivePortal ? "🔒" : nil
    }
}

/// The traffic-light dot as a SwiftUI view, at any size.
struct StatusDot: View {
    var status: DisplayStatus
    var diameter: CGFloat = 12

    var body: some View {
        if let emoji = status.emoji {
            Text(emoji).font(.system(size: diameter * 0.8))
        } else {
            switch status {
            case .measuring:
                Circle()
                    .strokeBorder(Color.secondary, lineWidth: max(1, diameter / 12))
                    .frame(width: diameter, height: diameter)
            case .level(.offline):
                Circle()
                    .fill(Color.black)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: max(1, diameter / 24)))
                    .frame(width: diameter, height: diameter)
            default:
                Circle()
                    .fill(status.color)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: max(1, diameter / 24)))
                    .frame(width: diameter, height: diameter)
            }
        }
    }
}

func formatMilliseconds(_ seconds: TimeInterval?) -> String {
    guard let seconds else { return "–" }
    let ms = seconds * 1000
    return ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)
}

func formatPercent(_ fraction: Double) -> String {
    String(format: "%.0f%%", fraction * 100)
}

/// Lines for the hover summary: status and latest result, 5-minute stats, what is probed.
func summaryLines(status: DisplayStatus, summary: SampleSummary, schedule: String) -> [String] {
    var lines: [String] = []
    if let last = summary.last {
        if let failure = last.failure {
            lines.append("\(status.name) — last probe failed: \(failure.description)")
        } else {
            lines.append("\(status.name) — \(formatMilliseconds(last.rtt))")
        }
    } else {
        lines.append(status.name)
    }
    if summary.count > 0 {
        lines.append("Last 5 min: median \(formatMilliseconds(summary.medianRTT)), "
            + "p90 \(formatMilliseconds(summary.p90RTT)), max \(formatMilliseconds(summary.maxRTT))")
        lines.append("Loss \(formatPercent(summary.loss)) (\(summary.failureCount) of \(summary.count) probes failed)")
    }
    lines.append(schedule)
    return lines
}
