import OnlineStatusCore
import SwiftUI

/// The main screen: a large status dot, the last five minutes of probes, and statistics.
struct StatusScreen: View {
    @ObservedObject var monitor: ConnectivityMonitor
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                content(now: monitor.now())
            }
            .navigationTitle("Online Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    MobileSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingSettings = false }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let start = now.addingTimeInterval(-ConnectivityMonitor.graphSpan)
        let recent = monitor.samples.filter { $0.date >= start }
        let summary = SampleSummary(recent)

        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    StatusDot(status: monitor.status, diameter: 88)
                        .accessibilityHidden(true)
                    Text(monitor.status.name)
                        .font(.title2.bold())
                    latency(summary: summary)
                }
                .padding(.top, 16)
                .accessibilityElement(children: .combine)

                LatencyChart(monitor: monitor, samples: recent, start: start, now: now)
                    .frame(height: 240)

                StatsGrid(summary: summary)

                Text(monitor.scheduleDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Probe Now") { monitor.probeNow() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func latency(summary: SampleSummary) -> some View {
        if let last = summary.last {
            if let failure = last.failure {
                Text(failure.description)
                    .font(.title3)
                    .foregroundStyle(.red)
            } else {
                Text(formatMilliseconds(last.rtt))
                    .font(.title3)
                    .monospacedDigit()
            }
        } else {
            Text("Waiting for the first probe…")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}
