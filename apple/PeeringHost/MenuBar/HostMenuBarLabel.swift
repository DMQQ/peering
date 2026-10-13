import AppKit
import MacCastKit
import RemoteCore
import SwiftUI

enum HostMenuBarState {
    case setupRequired
    case streaming
    case ready
    case waiting
    case stopped

    var symbol: String {
        switch self {
        case .streaming, .ready, .waiting: return "iphone"
        case .setupRequired: return "exclamationmark.triangle"
        case .stopped: return "iphone.slash"
        }
    }

    /// System semantic colours: a coloured glyph is not a template, so it must be legible on both menu bar appearances.
    var colour: NSColor {
        switch self {
        case .streaming: return .systemGreen
        case .ready: return .systemBlue
        case .waiting: return .secondaryLabelColor
        case .setupRequired: return .systemOrange
        case .stopped: return .systemRed
        }
    }

    var description: String {
        switch self {
        case .streaming: return String(localized: "A device is connected")
        case .ready: return String(localized: "Hosting, with a paired device")
        case .waiting: return String(localized: "Hosting, with no device paired")
        case .setupRequired: return String(localized: "Setup required")
        case .stopped: return String(localized: "Not hosting")
        }
    }
}

/// macOS draws a menu bar extra as a template and discards symbol tints, so the colour is baked into an NSImage with isTemplate off.
struct HostMenuBarLabel: View {
    let state: HostMenuBarState

    var body: some View {
        Image(nsImage: Self.image(for: state))
            .accessibilityLabel(state.description)
    }

    private static func image(for state: HostMenuBarState) -> NSImage {
        guard let pears = NSImage(named: "MenuBarPears") else { return NSImage() }
        let size = NSSize(width: 20, height: 18)
        // Drawn in the handler so `labelColor` resolves against the menu bar's appearance each
        // time; a coloured dot means the image cannot be a template.
        let image = NSImage(size: size, flipped: false) { rect in
            let glyph = NSRect(x: 0, y: 0, width: 18, height: 18)
            NSColor.labelColor.withAlphaComponent(state == .stopped ? 0.5 : 1).setFill()
            glyph.fill()
            pears.draw(in: glyph, from: .zero, operation: .destinationIn, fraction: 1)

            let dot = NSRect(x: rect.maxX - 7, y: 0, width: 7, height: 7)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            state.colour.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
