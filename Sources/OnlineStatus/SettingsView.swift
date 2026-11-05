import OnlineStatusCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    private typealias Key = MonitorSettings.Key

    @AppStorage(Key.mode) private var mode = ProbeMode.ping.rawValue
    @AppStorage(Key.pingHost) private var pingHost = MonitorSettings.defaultPingHost
    @AppStorage(Key.url) private var url = MonitorSettings.defaultURL
    @AppStorage(Key.httpExpectation) private var expectation = HTTPExpectation.noContent.rawValue
    @AppStorage(Key.interval) private var interval = 10.0
    @AppStorage(Key.timeout) private var timeout = 3.0
    @AppStorage(Key.goodLatencyMs) private var goodLatencyMs = 150.0
    @AppStorage(Key.poorLatencyMs) private var poorLatencyMs = 500.0
    @AppStorage(Key.recoverySeconds) private var recoverySeconds = 30.0

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("Check") {
                Picker("Method", selection: $mode) {
                    ForEach(ProbeMode.allCases, id: \.rawValue) { mode in
                        Text(mode.name).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                if mode == ProbeMode.ping.rawValue {
                    TextField("Host (IPv4)", text: $pingHost, prompt: Text(MonitorSettings.defaultPingHost))
                } else {
                    TextField("URL", text: $url, prompt: Text(MonitorSettings.defaultURL))
                    Picker("Success when", selection: $expectation) {
                        ForEach(HTTPExpectation.allCases, id: \.rawValue) { expectation in
                            Text(expectation.name).tag(expectation.rawValue)
                        }
                    }
                    Text("Redirects are not followed. A redirect, or a 200 when 204 is expected, "
                        + "is shown as 🔒 (Wi-Fi login required).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Stepper(value: $interval, in: 5...600, step: 5) {
                    LabeledContent("Check every", value: "\(Int(interval)) s")
                }
                Stepper(value: $timeout, in: 1...30, step: 1) {
                    LabeledContent("Timeout", value: "\(Int(timeout)) s")
                }
                if timeout > interval {
                    Text("The timeout is capped at the check interval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Thresholds") {
                Stepper(value: $goodLatencyMs, in: 10...2000, step: 10) {
                    LabeledContent("Good below", value: "\(Int(goodLatencyMs)) ms")
                }
                Stepper(value: $poorLatencyMs, in: 50...10000, step: 50) {
                    LabeledContent("Poor above", value: "\(Int(poorLatencyMs)) ms")
                }
                Stepper(value: $recoverySeconds, in: 0...600, step: 10) {
                    LabeledContent("Wait before improving", value: "\(Int(recoverySeconds)) s per level")
                }
                Text("Good: no failures, median latency below the good threshold. "
                    + "Mixed: up to 20% failures or median below the poor threshold. "
                    + "Poor: anything worse. No connectivity: two failures in a row. "
                    + "The status drops immediately but improves one level at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Restore Defaults", action: restoreDefaults)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func restoreDefaults() {
        for key in MonitorSettings.defaults.keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
