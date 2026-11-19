import OnlineStatusCore
import SwiftUI

/// The popover shown when the menu bar icon is clicked: last five minutes of probes.
struct GraphView: View {
    @ObservedObject var monitor: ConnectivityMonitor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            content(now: monitor.now())
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
            LatencyChart(monitor: monitor, samples: recent, start: start, now: now)
                .frame(height: 180)
            StatsGrid(summary: summary)
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

    private var footer: some View {
        HStack {
            Text(monitor.scheduleDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Probe Now") { monitor.probeNow() }
        }
        .controlSize(.small)
    }
}
