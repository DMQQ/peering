import AppKit
import SwiftUI

/// What the menu bar icon is saying.
///
/// Four states rather than the two this had, and the third question is why: the icon is read
/// from across a room, and "is a device attached" without "is this Mac available at all" leaves
/// the most common state — hosting, nobody connected — looking like the least useful one.
enum HostMenuBarState {
    /// A device is attached and the screen is going out.
    case streaming
    /// Hosting, with at least one device paired. Reachable the moment one asks.
    case ready
    /// Hosting, but nothing has ever paired. Reachable, and to nobody.
    case waiting
    /// Not hosting at all.
    case stopped

    var symbol: String {
        switch self {
        case .streaming, .ready, .waiting: return "iphone"
        case .stopped: return "iphone.slash"
        }
    }

    /// The system's own colours rather than picked ones, because this icon cannot adapt. See
    /// ``HostMenuBarLabel`` — a coloured glyph is no longer a template, which means it no longer
    /// follows the menu bar's light and dark appearance, so every one of these has to be legible
    /// on both. Apple's semantic colours are the ones with that property already worked out.
    var colour: NSColor {
        switch self {
        case .streaming: return .systemGreen
        case .ready: return .systemBlue
        case .waiting: return .secondaryLabelColor
        case .stopped: return .systemRed
        }
    }

    var description: String {
        switch self {
        case .streaming: return "A device is connected"
        case .ready: return "Hosting, with a paired device"
        case .waiting: return "Hosting, with no device paired"
        case .stopped: return "Not hosting"
        }
    }
}

/// The menu bar icon: whether a device is attached, and whether this Mac is available at all.
///
/// The host is a background agent, so this question is asked with the window shut — which is
/// almost always. The window is where the host is set up; this is where it is glanced at.
///
/// **Why the icon had to stop being a template to carry a colour.** macOS draws a menu bar extra
/// as a *template* image: it keeps the shape and paints it in the menu bar's own foreground
/// colour. A tint applied to a symbol is therefore discarded, and every state comes out the same
/// shade — which is exactly what this icon used to do, and why its two states had to differ by
/// shape instead.
///
/// The way out is not to ship a template. The symbol is rendered into an `NSImage` with the
/// colour already in it and `isTemplate` is turned off, which makes the colour part of the
/// artwork rather than a hint macOS is free to ignore.
///
/// The cost is that the icon no longer follows the menu bar's appearance on its own — see
/// ``HostMenuBarState/colour`` — and shape still carries the state as well, so it reads for
/// anyone who cannot tell the colours apart.
struct HostMenuBarLabel: View {
    let state: HostMenuBarState

    var body: some View {
        Image(nsImage: Self.image(for: state))
            .accessibilityLabel(state.description)
    }

    private static func image(for state: HostMenuBarState) -> NSImage {
        guard let base = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)
        else { return NSImage() }

        // Falls back to the uncoloured symbol rather than to nothing: a template glyph is a
        // worse icon than this one and a far better one than an empty space in the menu bar.
        let coloured = base.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [state.colour])
        ) ?? base
        coloured.isTemplate = false
        return coloured
    }
}

/// The menu itself. Built when it is opened, so the elapsed times are current to the second
/// the user looked rather than to whenever the model last changed.
struct HostMenuBarContent: View {
    @Environment(HostModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.connectedClients.isEmpty {
            Text(model.status.isListening ? "Waiting for a device" : "Not hosting")
        } else {
            ForEach(model.connectedClients) { client in
                Text("\(client.name) · \(client.elapsedDescription())")
            }
        }

        Divider()

        Button(model.status.isListening ? "Stop hosting" : "Start hosting") {
            model.status.isListening ? model.stop() : model.start()
        }

        Button("Open Peering") {
            openWindow(id: MacCastHostApp.mainWindowID)
            // The window may open behind whatever has focus; a menu bar item that appears to do
            // nothing is worse than one that is missing.
            NSApp.activate()
        }

        Divider()

        Button("Quit Peering") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
