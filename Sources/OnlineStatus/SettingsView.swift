import OnlineStatusCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var logger: ConnectivityLogger
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
    @AppStorage(Key.tetheredBackoff) private var tetheredBackoff = true
    @AppStorage(Key.tetheredInterval) private var tetheredInterval = 30.0
    @AppStorage(Key.pulseOnDrop) private var pulseOnDrop = true

    @AppStorage(Key.logEnabled) private var logEnabled = false
    @AppStorage(Key.logRetentionDays) private var logRetentionDays = 90
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        // Tabs keep each page short enough for small screens; pages scroll if needed.
        TabView {
            checkTab
                .tabItem { Label("Check", systemImage: "antenna.radiowaves.left.and.right") }
            statusTab
                .tabItem { Label("Status", systemImage: "circle.lefthalf.filled") }
            logTab
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 480)
    }

    private var checkTab: some View {
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
                    if case .failure(let problem) = MonitorSettings.validateURL(url) {
                        Text(problem.description)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

            Section("Personal hotspot") {
                Toggle("Check less often when tethered", isOn: $tetheredBackoff)
                if tetheredBackoff {
                    Stepper(value: $tetheredInterval, in: 5...600, step: 5) {
                        LabeledContent("Check every", value: "\(Int(max(tetheredInterval, interval))) s")
                    }
                }
                Text("Applies when macOS marks the network as expensive (an iPhone or other personal "
                    + "hotspot) or Low Data Mode is on, to save your data plan. "
                    + "Never more often than the normal interval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var statusTab: some View {
        Form {
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

            Section("Attention") {
                Toggle("Pulse the icon when the connection gets worse", isOn: $pulseOnDrop)
                Text("When the status gets worse (for example green to yellow), the icon pulses "
                    + "for about 12 seconds. Click the icon to stop it. With Reduce Motion on, "
                    + "the icon shows a steady highlight instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var logTab: some View {
        Form {
            Section("Log") {
                Toggle("Log connectivity with network and location", isOn: $logEnabled)
                if logEnabled {
                    Picker("Keep entries for", selection: $logRetentionDays) {
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("180 days").tag(180)
                        Text("1 year").tag(365)
                        Text("Forever").tag(0)
                    }
                    if !logger.isLocationAuthorized && logger.locationAuthorization != .notDetermined {
                        HStack {
                            Text("Location Services is off for Online Status, so the log has no "
                                + "Wi-Fi names or coordinates.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Open Settings…") { logger.openLocationSettings() }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Show in Finder") { logger.revealInFinder() }
                        Button("Export…") { logger.export() }
                    }
                    if let error = logger.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                Text("One row per stretch of time at the same status, network and place, as CSV. "
                    + "Wi-Fi names and coordinates need Location Services permission. "
                    + "The log stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
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
