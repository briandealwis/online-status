import AppKit
import OnlineStatusCore
import SwiftUI

extension DisplayStatus {
    var nsColor: NSColor {
        switch self {
        case .measuring: return .tertiaryLabelColor
        case .captivePortal: return .black
        case .level(let level):
            switch level {
            case .good: return .systemGreen
            case .mixed: return .systemYellow
            case .poor: return .systemRed
            case .offline: return .black
            }
        }
    }

}

/// Draws the traffic-light circle.
///
/// - Parameters:
///   - haloSpace: extra margin around the dot for the attention halo. The menu bar always
///     reserves it, so the item doesn't change width when a pulse starts.
///   - pulse: 0 for the plain dot; up to 1 for full attention (a halo in the status colour,
///     and a black dot glowing red).
func statusImage(for status: DisplayStatus, diameter: CGFloat = 12,
                 haloSpace: CGFloat = 0, pulse: CGFloat = 0) -> NSImage {
    let side = diameter + 2 + haloSpace * 2
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        let pulse = min(max(pulse, 0), 1)
        let isBlack = status == .level(.offline) || status == .captivePortal
        let accent: NSColor = isBlack ? .systemRed : status.nsColor

        if pulse > 0 && haloSpace > 0 {
            let halo = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            accent.withAlphaComponent(0.6 * pulse).setFill()
            halo.fill()
        }

        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: haloSpace + 1.5, dy: haloSpace + 1.5))
        circle.lineWidth = 1
        switch status {
        case .measuring:
            NSColor.labelColor.withAlphaComponent(0.5).setStroke()
            circle.stroke()
        case .level(.offline), .captivePortal:
            // Outline keeps the black dot visible on a dark menu bar.
            (NSColor.black.blended(withFraction: 0.85 * pulse, of: .systemRed) ?? .black).setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.6).setStroke()
            circle.stroke()
        default:
            status.nsColor.setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            circle.stroke()
        }
        return true
    }
    image.isTemplate = false
    return image
}
