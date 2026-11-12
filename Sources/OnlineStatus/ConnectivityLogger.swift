import AppKit
import UniformTypeIdentifiers
import CoreLocation
import CoreWLAN
import OnlineStatusCore

/// Writes the optional CSV log: one row per stretch of time at the same status, on the same
/// network, in the same area. The file stays on this Mac.
@MainActor
final class ConnectivityLogger: NSObject, ObservableObject {
    /// Location Services permission, for the Settings window.
    @Published private(set) var locationAuthorization: CLAuthorizationStatus
    @Published private(set) var lastError: String?

    let fileURL: URL
    private let directoryURL: URL
    private let locationManager = CLLocationManager()
    private let formatter = ConnectivityLogCSV.makeDateFormatter()
    private var recorder = SegmentRecorder()
    private var location: Coordinate?
    private var enabled = false
    private var retentionDays = 90
    private var lastPrune: Date?

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directoryURL = support.appendingPathComponent("OnlineStatus", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("connectivity-log.csv")
        locationAuthorization = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        // Neighbourhood-level accuracy is plenty, and cheaper on power.
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 100
    }

    var isLocationAuthorized: Bool { Self.isAuthorized(locationAuthorization) }

    /// Apply the current settings.
    func configure(enabled: Bool, retentionDays: Int) {
        let retentionChanged = retentionDays != self.retentionDays
        self.retentionDays = retentionDays
        if enabled != self.enabled {
            self.enabled = enabled
            if enabled {
                startLocation()
            } else {
                flush(at: Date())
                locationManager.stopUpdatingLocation()
                location = nil
            }
        }
        if enabled { pruneIfDue(force: retentionChanged) }
    }

    /// Adds a probe result. Writes a row whenever a stretch ends.
    func record(_ sample: Sample, status: DisplayStatus, kind: NetworkKind, expensive: Bool) {
        guard enabled else { return }
        let context = LogContext(network: networkName(kind: kind, expensive: expensive), location: location)
        if let segment = recorder.record(sample, status: status, context: context) {
            append(segment)
        }
    }

    /// Ends the current stretch now (sleep, quit, network change, logging turned off).
    func flush(at date: Date) {
        if let segment = recorder.close(at: date) {
            append(segment)
        }
    }

    func revealInFinder() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directoryURL)
        }
    }

    /// Lets the user save a copy of the log anywhere.
    func export() {
        flush(at: Date())
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "connectivity-log.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.copyItem(at: fileURL, to: destination)
            } else {
                try (ConnectivityLogCSV.header + "\n").write(to: destination, atomically: true, encoding: .utf8)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private

    private func startLocation() {
        if locationAuthorization == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if isLocationAuthorized {
            locationManager.startUpdatingLocation()
        }
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        switch status {
        case .notDetermined, .restricted, .denied: return false
        default: return true
        }
    }

    /// E.g. "Wi-Fi: TrainNet", "Hotspot: Brian's iPhone", "Tethered (USB)", "Ethernet".
    /// The Wi-Fi name is only available with Location Services permission.
    private func networkName(kind: NetworkKind, expensive: Bool) -> String {
        switch kind {
        case .wifi:
            let ssid = CWWiFiClient.shared().interface()?.ssid()
            let prefix = expensive ? "Hotspot" : "Wi-Fi"
            return ssid.map { "\(prefix): \($0)" } ?? prefix
        case .ethernet:
            return expensive ? "Tethered (USB)" : "Ethernet"
        case .cellular:
            return "Cellular"
        case .other:
            return expensive ? "Tethered" : "Other"
        case .none:
            return "No network"
        }
    }

    private func append(_ segment: LogSegment) {
        let line = ConnectivityLogCSV.row(segment, formatter: formatter) + "\n"
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try (ConnectivityLogCSV.header + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        pruneIfDue(force: false)
    }

    /// Drop rows older than the retention period, at most every few hours.
    private func pruneIfDue(force: Bool) {
        guard retentionDays > 0 else { return }
        let now = Date()
        if !force, let lastPrune, now.timeIntervalSince(lastPrune) < 6 * 60 * 60 { return }
        lastPrune = now
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        let pruned = ConnectivityLogCSV.prune(contents, before: cutoff, formatter: formatter)
        if pruned != contents {
            try? pruned.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    fileprivate func locationChanged(_ coordinate: Coordinate) {
        location = coordinate
    }

    fileprivate func authorizationChanged(_ status: CLAuthorizationStatus) {
        locationAuthorization = status
        if enabled && Self.isAuthorized(status) {
            locationManager.startUpdatingLocation()
        } else {
            locationManager.stopUpdatingLocation()
            location = nil
        }
    }
}

extension ConnectivityLogger: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last, last.horizontalAccuracy >= 0 else { return }
        let coordinate = Coordinate(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude,
                                    accuracy: last.horizontalAccuracy)
        Task { @MainActor in self.locationChanged(coordinate) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location is optional: keep logging without it.
    }
}
