import AppKit
import OnlineStatusCore
import SwiftUI

/// Shows a small live-updating summary panel while the pointer rests on the menu bar icon.
/// (A plain `toolTip` on a status item is unreliable and doesn't update while shown.)
@MainActor
final class HoverSummary: NSResponder {
    private let panel: NSPanel
    private let hosting: NSHostingView<HoverSummaryView>
    private weak var button: NSStatusBarButton?
    private var showTask: Task<Void, Never>?
    /// Return true to keep the panel hidden, e.g. while the graph popover is open.
    var isSuppressed: () -> Bool = { false }

    init(monitor: ConnectivityMonitor, button: NSStatusBarButton) {
        hosting = NSHostingView(rootView: HoverSummaryView(monitor: monitor))
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = hosting
        self.button = button
        super.init()
        button.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseEntered(with event: NSEvent) {
        showTask?.cancel()
        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.show()
        }
    }

    override func mouseExited(with event: NSEvent) {
        hide()
    }

    func hide() {
        showTask?.cancel()
        showTask = nil
        panel.orderOut(nil)
    }

    private func show() {
        guard !isSuppressed(), let button, let window = button.window else { return }
        let size = hosting.fittingSize
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(x: buttonFrame.midX - size.width / 2, y: buttonFrame.minY - size.height - 4)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}

struct HoverSummaryView: View {
    @ObservedObject var monitor: ConnectivityMonitor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let lines = summaryLines(status: monitor.status, summary: monitor.recentSummary,
                                     settings: monitor.settings)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .fontWeight(index == 0 ? .semibold : .regular)
                        .foregroundStyle(index == lines.count - 1 ? .secondary : .primary)
                }
            }
            .font(.callout)
            .monospacedDigit()
            .frame(width: 340, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
