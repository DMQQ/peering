import AppKit
import CoreImage
import RemoteCore

/// The card drawn in a tile of a mosaic that has no picture in it.
///
/// Drawn by the Mac because the Mac is the only end that knows: a tile is blank when a capture
/// could not be built for it, and nothing in the protocol says so. The client asked for a canvas
/// and a canvas is what it gets, so it cannot tell a tile with nothing to show from a tile
/// showing something black. The catalogue cannot answer it either: it is what the Mac offers, and
/// an application with no windows is not in it, which is the whole reason the tile is blank.
///
/// Drawn in the canvas rather than in the client's chrome, so a phone zooming into the tile
/// magnifies the card with the picture instead of leaving it the size of the phone's text.
enum MosaicPlaceholder {
    /// What one card says.
    struct Content {
        /// The name of the thing that is not there, where anything still knows it.
        var title: String?
        /// What is wrong with it, in the few words a tile has room for.
        var message: String
        /// The application's icon, where there is one. `nil` draws the mark instead.
        var icon: NSImage?
    }

/// A card that is drawn the first time somebody asks for it.
///
/// Not built with the plan that carries it: a plan is made on every ask, and a healthy tile never
/// shows a card, so drawing eagerly is one offscreen bitmap render per tile, up to 1440 pixels
/// tall with its own text layout, on the path whose speed is the complaint.
    final class Card: @unchecked Sendable {
        private let content: Content
        private let size: CGSize
        private let lock = NSLock()
        private var built = false
        private var image: CIImage?

        init(content: Content, size: CGSize) {
            self.content = content
            self.size = size
        }

        var picture: CIImage? {
            lock.withLock {
                guard !built else { return image }
                built = true
                image = MosaicPlaceholder.image(content, size: size)
                return image
            }
        }
    }

/// The card, at the size of the tile it will be drawn in.
///
/// `nil` when there is no card to draw at all: a tile too small to hold one, or a bitmap that
/// could not be allocated. A card that could not be built is not a reason to fail a mosaic.
    static func image(_ content: Content, size: CGSize) -> CIImage? {
        let width = Int(size.width.rounded(.down))
        let height = Int(size.height.rounded(.down))
// Below this there is no room for a mark and a line of text anybody could read, and a tile that
// small is a thumbnail rather than a picture of a window. It stays black.
        guard width >= 24, height >= 24 else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

// Everything is a fraction of the tile's height, so one card is one design at any size: a canvas
// has tiles from 480 to 1440 pixels high depending on how many of them there are.
        let bounds = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let markSide = min(bounds.height * 0.30, bounds.width * 0.20)
        let gap = min(max(bounds.height * 0.03, 3), 24)
        let textWidth = bounds.width * 0.86

        let titleFont = NSFont.systemFont(ofSize: min(max(bounds.height * 0.072, 11), 44), weight: .semibold)
        let messageFont = NSFont.systemFont(ofSize: min(max(bounds.height * 0.058, 10), 36))
// Explicitly white and explicitly dim rather than the semantic colours: this is drawn offscreen,
// where "secondary label" resolves against the light appearance and comes out as a dark grey on
// a black tile.
        let muted = NSColor.white.withAlphaComponent(0.62)

        let title = content.title.flatMap { $0.isEmpty ? nil : $0 }
        let titleLine = title.map { styled($0, font: titleFont, colour: .white).size() }
        let messageLine = styled(content.message, font: messageFont, colour: muted).size()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

// The tile's own black, so a card is the tile rather than a bright patch in it.
        NSColor.black.setFill()
        bounds.fill()

// Measured first and drawn second, so the block can be centred as a whole; centring each line on
// its own spaces the lines by their own heights, which looks centred and drifts as the text
// changes.
        var block = markSide + gap
        if let titleLine { block += titleLine.height + gap * 0.5 }
        block += messageLine.height

        // AppKit's origin is the bottom left, so the block starts at the top and walks down.
        var top = bounds.midY + block / 2

        (content.icon ?? mark).draw(
            in: NSRect(x: bounds.midX - markSide / 2, y: top - markSide, width: markSide, height: markSide),
            from: .zero, operation: .sourceOver, fraction: 1
        )
        top -= markSide + gap

        if let title, let titleLine {
            let rect = NSRect(
                x: bounds.midX - textWidth / 2, y: top - titleLine.height,
                width: textWidth, height: titleLine.height
            )
            styled(title, font: titleFont, colour: .white).draw(in: rect)
            top -= titleLine.height + gap * 0.5
        }

        styled(content.message, font: messageFont, colour: muted).draw(
            in: NSRect(
                x: bounds.midX - textWidth / 2, y: top - messageLine.height,
                width: textWidth, height: messageLine.height
            )
        )

        guard let cgImage = rep.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

/// The mark for "nothing here": the symbol this app uses wherever a picture is missing.
///
/// White, because it is drawn into a black tile rather than into the app's own chrome. An empty
/// image if the symbol cannot be made, which draws nothing. A card with a name and a reason on it
/// is still a card.
    private static let mark: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: "video.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage(size: .zero)
    }()

    private static func styled(_ text: String, font: NSFont, colour: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: colour,
            .paragraphStyle: style,
        ])
    }
}

extension MosaicPlaceholder.Content {
/// What to say about a source the plan could not build a capture for.
///
/// The reason comes from the system and the name from whatever still remembers it: the catalogue
/// is asked first because it is where a tile's name lives, and the process table second because it
/// still has the name and icon of an application running with nothing open.
    static func missing(_ source: CaptureSource, descriptor: CaptureSourceDescriptor?) -> Self {
        let icon = descriptor?.iconPNGData.flatMap { NSImage(data: $0) }

        switch source {
        case .application(let processID):
            let running = NSRunningApplication(processIdentifier: processID)
            return Self(
                title: descriptor?.title ?? running?.localizedName,
                message: running == nil ? "This application has quit" : "No windows open",
                icon: icon ?? running?.icon
            )
        case .window:
// A window has no name of its own once it has gone, so this is a card with a mark and a sentence,
// which is what there is to say.
            return Self(title: descriptor?.title, message: "This window has closed", icon: icon)
        case .display:
            return Self(title: descriptor?.title, message: "This display is not available", icon: icon)
        case .mosaic:
// Unreachable: a mosaic is never one of a mosaic's tiles. Said rather than crashed so a future
// backend cannot make it reachable in silence.
            return Self(title: nil, message: "Nothing to show", icon: nil)
        }
    }

/// What to say about a tile that has a capture and no picture in it.
///
/// The compositor knows that a tile is empty, from the frame's own content rectangle, and not why:
/// the window may have been closed, moved to another Space, or hidden.
    static func empty(descriptor: CaptureSourceDescriptor?) -> Self {
        Self(
            title: descriptor?.title,
            message: "Nothing to show",
            icon: descriptor?.iconPNGData.flatMap { NSImage(data: $0) }
        )
    }
}
