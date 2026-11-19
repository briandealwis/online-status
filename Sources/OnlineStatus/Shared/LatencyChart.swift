import Charts
import OnlineStatusCore
import SwiftUI

/// Latency over a time range on a log scale: background shaded by status, dashed good and poor
/// thresholds, red ticks for failed probes, and a line that breaks at each failure.
struct LatencyChart: View {
    @ObservedObject var monitor: ConnectivityMonitor
    /// Samples in the range, oldest first.
    var samples: [Sample]
    var start: Date
    var now: Date

    private struct Point: Identifiable {
        var date: Date
        var ms: Double
        /// Consecutive successful probes share a run; the line is only drawn within a run.
        var run: Int
        var id: Date { date }
    }

    private struct Band: Identifiable {
        var start: Date
        var end: Date
        var status: DisplayStatus
        var id: Date { start }
    }

    private func bands() -> [Band] {
        let changes = monitor.statusChanges
        var result: [Band] = []
        for (index, change) in changes.enumerated() {
            let end = index + 1 < changes.count ? changes[index + 1].date : now
            guard end > start else { continue }
            result.append(Band(start: max(change.date, start), end: end, status: change.status))
        }
        return result
    }

    /// Every whole minute inside the visible range.
    private var minuteTicks: [Date] {
        var tick = (start.timeIntervalSince1970 / 60).rounded(.up) * 60
        var ticks: [Date] = []
        while tick <= now.timeIntervalSince1970 {
            ticks.append(Date(timeIntervalSince1970: tick))
            tick += 60
        }
        return ticks
    }

    var body: some View {
        // A failed probe breaks the line: nothing was measured until the next success.
        let points = SuccessRun.split(samples).flatMap { run in
            run.samples.compactMap { sample in
                sample.rtt.map { Point(date: sample.date, ms: $0 * 1000, run: run.index) }
            }
        }
        let failures = samples.filter { !$0.isSuccess }.map(\.date)
        let good = monitor.settings.goodLatencyMs
        let poor = monitor.settings.poorLatencyMs
        let top = max(poor * 2, (points.map(\.ms).max() ?? 0) * 1.3, 100)

        Chart {
            ForEach(bands()) { band in
                RectangleMark(xStart: .value("From", band.start), xEnd: .value("To", band.end))
                    .foregroundStyle(band.status.color.opacity(band.status == .measuring ? 0.05 : 0.15))
            }
            RuleMark(y: .value("Good", good))
                .foregroundStyle(.green.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            RuleMark(y: .value("Poor", poor))
                .foregroundStyle(.red.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(failures, id: \.self) { date in
                RuleMark(x: .value("Failed", date))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(points) { point in
                LineMark(x: .value("Time", point.date), y: .value("Latency (ms)", point.ms),
                         series: .value("Run", point.run))
                    .foregroundStyle(.primary)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Time", point.date), y: .value("Latency (ms)", point.ms))
                    .foregroundStyle(.primary)
                    .symbolSize(12)
            }
        }
        // Inset the time range by about half a label's width so labels centred on ticks
        // near either end aren't clipped or hidden.
        .chartXScale(domain: start...now, range: .plotDimension(padding: 24))
        .chartYScale(domain: 1...top, type: .log)
        .chartXAxis {
            AxisMarks(values: minuteTicks) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute(), collisionResolution: .disabled)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [1, 10, 100, 1000, 10000].filter { $0 <= top }) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let ms = value.as(Double.self) {
                        Text(ms >= 1000 ? "\(Int(ms / 1000)) s" : "\(Int(ms)) ms")
                    }
                }
            }
        }
    }
}

/// Median, p90, min/max, loss and probe count.
struct StatsGrid: View {
    var summary: SampleSummary

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
            GridRow {
                Text("Median").foregroundStyle(.secondary)
                Text("p90").foregroundStyle(.secondary)
                Text("Min / Max").foregroundStyle(.secondary)
                Text("Loss").foregroundStyle(.secondary)
                Text("Probes").foregroundStyle(.secondary)
            }
            GridRow {
                Text(formatMilliseconds(summary.medianRTT))
                Text(formatMilliseconds(summary.p90RTT))
                Text("\(formatMilliseconds(summary.minRTT)) / \(formatMilliseconds(summary.maxRTT))")
                Text(formatPercent(summary.loss))
                Text("\(summary.count)")
            }
            .monospacedDigit()
        }
        .font(.callout)
    }
}
