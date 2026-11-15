import AppKit
import Combine
import OnlineStatusCore
import SwiftUI

@main
enum OnlineStatusMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--screenshots") {
            let directory = index + 1 < arguments.count ? arguments[index + 1] : "docs/screenshots"
            exit(Screenshots.run(into: URL(fileURLWithPath: directory, isDirectory: true)))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only: no Dock icon or app menu.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = ConnectivityMonitor()
    private let logger = ConnectivityLogger()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hoverSummary: HoverSummary?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    // Attention pulse when the connection gets worse.
    private static let pulsePeriod: TimeInterval = 1.2
    /// Ten whole pulses, so the animation ends at rest.
    private static let pulseDuration: TimeInterval = pulsePeriod * 10
    private static let haloSpace: CGFloat = 3
    private var lastStatus: DisplayStatus = .measuring
    private var pulseTimer: Timer?
    private var pulseStart = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.imagePosition = .imageOnly
        statusItem = item
        if let button = item.button {
            let hover = HoverSummary(monitor: monitor, button: button)
            hover.isSuppressed = { [weak self] in self?.popover.isShown ?? false }
            hoverSummary = hover
        }

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: GraphView(
                monitor: monitor,
                openSettings: { [weak self] in self?.showSettings() },
                quit: { NSApp.terminate(nil) }
            )
        )

        monitor.$status
            .combineLatest(monitor.$samples, monitor.$settings, monitor.$onExpensiveNetwork)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        // Connectivity log.
        monitor.onRecord = { [weak self] sample, status in
            guard let self else { return }
            logger.record(sample, status: status, kind: monitor.networkKind,
                          expensive: monitor.onExpensiveNetwork)
        }
        monitor.onSleep = { [weak self] in self?.logger.flush(at: Date()) }
        monitor.$settings
            .sink { [weak self] settings in
                self?.logger.configure(enabled: settings.logEnabled, retentionDays: settings.logRetentionDays)
            }
            .store(in: &cancellables)
        monitor.$status
            .filter { $0 == .measuring }
            .sink { [weak self] _ in self?.logger.flush(at: Date()) }
            .store(in: &cancellables)

        monitor.start()
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.flush(at: Date())
    }

    private func updateStatusItem() {
        let status = monitor.status
        if status != lastStatus {
            if status.isAlarmingDrop(from: lastStatus) && monitor.settings.pulseOnDrop && !popover.isShown {
                startPulse()
            } else if (status.level ?? .good) > (lastStatus.level ?? .good) || status == .measuring {
                // Improved (or measuring again): no need for attention any more.
                stopPulse()
            }
            lastStatus = status
        }
        if !monitor.settings.pulseOnDrop { stopPulse() }
        drawIcon(pulse: currentPulse)
    }

    private func drawIcon(pulse: CGFloat) {
        guard let button = statusItem?.button else { return }
        let status = monitor.status
        if let emoji = status.emoji {
            button.image = nil
            button.title = emoji
            button.imagePosition = .noImage
            button.alphaValue = 1 - 0.7 * pulse
        } else {
            button.title = ""
            button.image = statusImage(for: status, haloSpace: Self.haloSpace, pulse: pulse)
            button.imagePosition = .imageOnly
            button.alphaValue = 1
        }
        button.setAccessibilityLabel("Connectivity: \(status.name)")
    }

    /// 0...1 for the current frame of the pulse; 0 when not pulsing.
    private var currentPulse: CGFloat {
        guard pulseTimer != nil else { return 0 }
        // With Reduce Motion on, show a steady highlight instead of flashing.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return 1 }
        let phase = Date().timeIntervalSince(pulseStart) / Self.pulsePeriod
        return CGFloat((1 - cos(2 * Double.pi * phase)) / 2)
    }

    private func startPulse() {
        pulseStart = Date()
        guard pulseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pulseTick() }
        }
        // .common keeps it running while a menu or the popover is tracking the mouse.
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private func pulseTick() {
        if Date().timeIntervalSince(pulseStart) >= Self.pulseDuration {
            stopPulse()
        } else {
            drawIcon(pulse: currentPulse)
        }
    }

    private func stopPulse() {
        guard let timer = pulseTimer else { return }
        timer.invalidate()
        pulseTimer = nil
        drawIcon(pulse: 0)
    }

    @objc private func togglePopover(_ sender: Any?) {
        hoverSummary?.hide()
        // Clicking the icon acknowledges the alert.
        stopPulse()
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            // Native Mac settings layout: one toolbar button per page.
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for page in SettingsView.Page.allCases {
                let controller = NSHostingController(rootView: SettingsView(logger: logger, page: page))
                controller.sizingOptions = [.preferredContentSize]
                let item = NSTabViewItem(viewController: controller)
                item.label = page.title
                item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
