import OnlineStatusCore
import SwiftUI

/// Settings on iPhone. Uses the same keys as the Mac app.
struct MobileSettingsView: View {
    private typealias Key = MonitorSettings.Key

    @AppStorage(Key.mode) private var mode = ProbeMode.ping.rawValue
    @AppStorage(Key.pingHost) private var pingHost = MonitorSettings.defaultPingHost
    @AppStorage(Key.url) private var url = MonitorSettings.defaultURL
    @AppStorage(Key.httpExpectation) private var expectation = HTTPExpectation.noContent.rawValue
    @AppStorage(Key.interval) private var interval = 10.0
    @AppStorage(Key.timeout) private var timeout = 3.0
    @AppStorage(Key.fastAfterChange) private var fastAfterChange = true
    @AppStorage(Key.fastInterval) private var fastInterval = 2.0
    @AppStorage(Key.fastDuration) private var fastDuration = 60.0
    @AppStorage(Key.tetheredBackoff) private var tetheredBackoff = true
    @AppStorage(Key.tetheredInterval) private var tetheredInterval = 30.0
    @AppStorage(Key.goodLatencyMs) private var goodLatencyMs = 150.0
    @AppStorage(Key.poorLatencyMs) private var poorLatencyMs = 500.0
    @AppStorage(Key.recoverySeconds) private var recoverySeconds = 30.0

    var body: some View {
        Form {
            Section("Probe") {
                Picker("Method", selection: $mode) {
                    ForEach(ProbeMode.allCases, id: \.rawValue) { mode in
                        Text(mode.name).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                if mode == ProbeMode.ping.rawValue {
                    LabeledContent("Host (IPv4)") {
                        TextField(MonitorSettings.defaultPingHost, text: $pingHost)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } else {
                    TextField(MonitorSettings.defaultURL, text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if case .failure(let problem) = MonitorSettings.validateURL(url) {
                        Text(problem.description)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Picker("Success when", selection: $expectation) {
                        ForEach(HTTPExpectation.allCases, id: \.rawValue) { expectation in
                            Text(expectation.name).tag(expectation.rawValue)
                        }
                    }
                }

                Stepper("Check every \(Int(interval)) s", value: $interval, in: 5...600, step: 5)
                Stepper("Timeout \(Int(timeout)) s", value: $timeout, in: 1...30, step: 1)
            }

            Section {
                Toggle("Check more often after a change", isOn: $fastAfterChange)
                if fastAfterChange {
                    Picker("Every", selection: $fastInterval) {
                        Text("1 s").tag(1.0)
                        Text("2 s").tag(2.0)
                        Text("5 s").tag(5.0)
                    }
                    Picker("For", selection: $fastDuration) {
                        Text("30 s").tag(30.0)
                        Text("1 min").tag(60.0)
                        Text("2 min").tag(120.0)
                        Text("5 min").tag(300.0)
                    }
                }
            } footer: {
                Text("When the status changes, probe faster for a while to see how long a drop lasts.")
            }

            Section {
                Toggle("Check less often on cellular", isOn: $tetheredBackoff)
                if tetheredBackoff {
                    Stepper("Check every \(Int(max(tetheredInterval, interval))) s",
                            value: $tetheredInterval, in: 5...600, step: 5)
                }
            } footer: {
                Text("Applies on cellular data and in Low Data Mode, to save your data plan.")
            }

            Section {
                Stepper("Good below \(Int(goodLatencyMs)) ms", value: $goodLatencyMs, in: 10...2000, step: 10)
                Stepper("Poor above \(Int(poorLatencyMs)) ms", value: $poorLatencyMs, in: 50...10000, step: 50)
                Stepper("Improve after \(Int(recoverySeconds)) s", value: $recoverySeconds, in: 0...600, step: 10)
            } header: {
                Text("Thresholds")
            } footer: {
                Text("The status drops immediately but improves one level at a time.")
            }

            Section {
                Button("Restore Defaults", role: .destructive) {
                    for key in MonitorSettings.defaults.keys {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
