import AppKit
import OnlineStatusCore
import SwiftUI

/// `OnlineStatus --screenshots <dir>` renders the app's panels with demo data into PNGs for
/// the README. It draws into off-screen windows, so it needs no Screen Recording permission
/// and works on a CI runner. The clock and data are fixed, so the images only change when
/// the UI does.
@MainActor
enum Screenshots {
    /// 08:45 UTC on a weekday morning commute.
    static let frozenNow = Date(timeIntervalSince1970: 1_773_305_100) // 2026-03-12 08:45:00 UTC

    static func run(into directory: URL) -> Int32 {
        // Fixed time zone and locale so labels such as "8:42 AM" are the same on every machine.
        NSTimeZone.default = TimeZone(identifier: "UTC")!
        UserDefaults.standard.set(["en_US"], forKey: "AppleLanguages")
        UserDefaults.standard.set("en_US", forKey: "AppleLocale")
        // Settings shown in the images: the defaults, with the log turned on.
        for key in MonitorSettings.defaults.keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.register(defaults: MonitorSettings.defaults)
        UserDefaults.standard.set(true, forKey: MonitorSettings.Key.logEnabled)

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let monitor = ConnectivityMonitor()
            monitor.loadDemo(demoSamples(), frozenNow: frozenNow)
            let logger = ConnectivityLogger()

            try render(
                panel(GraphView(monitor: monitor)),
                to: directory.appendingPathComponent("graph.png")
            )
            try render(
                HoverSummaryView(monitor: monitor).padding(12),
                to: directory.appendingPathComponent("hover.png")
            )
            for page in SettingsView.Page.allCases {
                try render(
                    SettingsView(logger: logger, page: page),
                    to: directory.appendingPathComponent("settings-\(page.title.lowercased()).png")
                )
            }
            print("Screenshots written to \(directory.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("Screenshots failed: \(error)\n".utf8))
            return 1
        }
    }

    /// A commute: steady, a slowdown, a brief outage, then recovery. One probe every 10 s
    /// over the five minutes the graph shows.
    static func demoSamples() -> [Sample] {
        let latencies: [Double?] = [
            24, 27, 22, 31, 26, 23, 29, 25, 28, 24, 26, 30,
            180, 240, 320, 410,
            nil, nil,
            520, 260, 140, 90,
            45, 38, 33, 30, 28, 31, 27, 29,
        ]
        let start = frozenNow.addingTimeInterval(-Double(latencies.count - 1) * 10)
        return latencies.enumerated().map { index, ms in
            let date = start.addingTimeInterval(Double(index) * 10)
            guard let ms else { return .failure(at: date, .timeout) }
            return .success(at: date, rtt: ms / 1000)
        }
    }

    /// Wraps a view in a popover-like card.
    private static func panel(_ content: some View) -> some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
            .padding(12)
    }

    enum RenderError: Error {
        case noImage(String)
    }

    /// Draws `view` at 2x into a PNG.
    private static func render(_ view: some View, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI and Swift Charts finish laying out and drawing.
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw RenderError.noImage(url.lastPathComponent) }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.noImage(url.lastPathComponent)
        }
        try png.write(to: url)
        window.close()
        print("  \(url.lastPathComponent): \(Int(size.width))×\(Int(size.height)) pt")
    }
}
