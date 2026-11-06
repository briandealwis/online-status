import AppKit
import Combine
import OnlineStatusCore
import SwiftUI

@main
enum OnlineStatusMain {
    @MainActor
    static func main() {
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
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hoverSummary: HoverSummary?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

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
            .combineLatest(monitor.$samples, monitor.$settings)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        monitor.start()
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let status = monitor.status
        if let emoji = status.emoji {
            button.image = nil
            button.title = emoji
            button.imagePosition = .noImage
        } else {
            button.title = ""
            button.image = statusImage(for: status)
            button.imagePosition = .imageOnly
        }
        button.setAccessibilityLabel("Connectivity: \(status.name)")
    }

    @objc private func togglePopover(_ sender: Any?) {
        hoverSummary?.hide()
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
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Online Status Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
