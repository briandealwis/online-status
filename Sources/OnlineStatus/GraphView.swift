import Charts
import OnlineStatusCore
import SwiftUI

/// The popover shown when the menu bar icon is clicked: last five minutes of probes.
struct GraphView: View {
    @ObservedObject var monitor: ConnectivityMonitor
    var openSettings: () -> Void
    var quit: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .padding(14)
        .frame(width: 440)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let start = now.addingTimeInterval(-ConnectivityMonitor.graphSpan)
        let recent = monitor.samples.filter { $0.date >= start }
        let summary = SampleSummary(recent)

        VStack(alignment: .leading, spacing: 10) {
            header(summary: summary)
            chart(samples: recent, start: start, now: now)
                .frame(height: 180)
            stats(summary: summary)
            Divider()
            footer
        }
    }

    private func header(summary: SampleSummary) -> some View {
        HStack(spacing: 8) {
            if let emoji = monitor.status.emoji {
                Text(emoji)
            } else {
                Image(nsImage: statusImage(for: monitor.status))
            }
            Text(monitor.status.name).font(.headline)
            Spacer()
            if let last = summary.last {
                if let failure = last.failure {
                    Text(failure.description).foregroundStyle(.red)
                } else {
                    Text(formatMilliseconds(last.rtt)).monospacedDigit()
                }
            }
        }
    }

    // MARK: Chart

    private struct Point: Identifiable {
        var date: Date
        var ms: Double
        var id: Date { date }
    }

    private struct Band: Identifiable {
        var start: Date
        var end: Date
        var status: DisplayStatus
        var id: Date { start }
    }

    private func bands(start: Date, now: Date) -> [Band] {
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
    private func minuteTicks(start: Date, now: Date) -> [Date] {
        var tick = (start.timeIntervalSince1970 / 60).rounded(.up) * 60
        var ticks: [Date] = []
        while tick <= now.timeIntervalSince1970 {
            ticks.append(Date(timeIntervalSince1970: tick))
            tick += 60
        }
        return ticks
    }

    /// Centre each time label under its tick, but slide the anchor towards the label's edge as the
    /// tick nears either end of the plot, so the label stays fully inside instead of being clipped
    /// to "…" or dropped.
    private func labelAnchor(for date: Date?, start: Date, now: Date) -> UnitPoint {
        guard let date else { return .top }
        // Seconds from an edge over which the anchor slides (about a label's width).
        let ramp: TimeInterval = 40
        let fromStart = date.timeIntervalSince(start)
        let fromEnd = now.timeIntervalSince(date)
        var x = 0.5
        if fromStart < ramp {
            x = max(0, fromStart / ramp) * 0.5
        } else if fromEnd < ramp {
            x = 1 - max(0, fromEnd / ramp) * 0.5
        }
        return UnitPoint(x: x, y: 0)
    }

    private func chart(samples: [Sample], start: Date, now: Date) -> some View {
        let points = samples.compactMap { sample in
            sample.rtt.map { Point(date: sample.date, ms: $0 * 1000) }
        }
        let failures = samples.filter { !$0.isSuccess }.map(\.date)
        let good = monitor.settings.goodLatencyMs
        let poor = monitor.settings.poorLatencyMs
        let top = max(poor * 2, (points.map(\.ms).max() ?? 0) * 1.3, 100)

        return Chart {
            ForEach(bands(start: start, now: now)) { band in
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
                LineMark(x: .value("Time", point.date), y: .value("Latency (ms)", point.ms))
                    .foregroundStyle(.primary)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Time", point.date), y: .value("Latency (ms)", point.ms))
                    .foregroundStyle(.primary)
                    .symbolSize(12)
            }
        }
        .chartXScale(domain: start...now)
        .chartYScale(domain: 1...top, type: .log)
        .chartXAxis {
            AxisMarks(values: minuteTicks(start: start, now: now)) { value in
                AxisGridLine()
                AxisValueLabel(
                    format: .dateTime.hour().minute(),
                    anchor: labelAnchor(for: value.as(Date.self), start: start, now: now),
                    collisionResolution: .disabled
                )
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

    // MARK: Stats and footer

    private func stats(summary: SampleSummary) -> some View {
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

    private var footer: some View {
        HStack {
            Text(monitor.scheduleDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Probe Now") { monitor.probeNow() }
            Button("Settings…", action: openSettings)
            Button("Quit", action: quit)
        }
        .controlSize(.small)
    }
}
