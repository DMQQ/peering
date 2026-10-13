import AppKit
import CoreImage
import RemoteCore

/// Drawn by the Mac because only it knows a tile is blank, and drawn in the canvas so a zoomed tile magnifies the card.
enum MosaicPlaceholder {
    struct Content {
        var title: String?
        var message: String
        var icon: NSImage?
    }

/// Drawn lazily: a healthy tile never shows a card, and eager drawing costs an offscreen bitmap per tile on the hot path.
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

/// nil for a tile too small to hold a card or a bitmap that could not be allocated.
    static func image(_ content: Content, size: CGSize) -> CIImage? {
        let width = Int(size.width.rounded(.down))
        let height = Int(size.height.rounded(.down))
// Below this there is no room for a readable mark and text; the tile stays black.
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

// Fractions of tile height, so one design fits tiles from 480 to 1440 px.
        let bounds = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let markSide = min(bounds.height * 0.30, bounds.width * 0.20)
        let gap = min(max(bounds.height * 0.03, 3), 24)
        let textWidth = bounds.width * 0.86

        let titleFont = NSFont.systemFont(ofSize: min(max(bounds.height * 0.072, 11), 44), weight: .semibold)
        let messageFont = NSFont.systemFont(ofSize: min(max(bounds.height * 0.058, 10), 36))
// Explicit colours: drawn offscreen, semantic colours resolve against the light appearance and come out dark grey.
        let muted = NSColor.white.withAlphaComponent(0.62)

        let title = content.title.flatMap { $0.isEmpty ? nil : $0 }
        let titleLine = title.map { styled($0, font: titleFont, colour: .white).size() }
        let messageLine = styled(content.message, font: messageFont, colour: muted).size()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.black.setFill()
        bounds.fill()

// Measured first so the block centres as a whole; centring each line drifts as text changes.
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

/// White because it is drawn into a black tile. Empty image if the symbol cannot be made.
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
/// Name from the catalogue first, then the process table, which still knows an application running with nothing open.
    static func missing(_ source: CaptureSource, descriptor: CaptureSourceDescriptor?) -> Self {
        let icon = descriptor?.iconPNGData.flatMap { NSImage(data: $0) }

        switch source {
        case .application(let processID):
            let running = NSRunningApplication(processIdentifier: processID)
            return Self(
                title: descriptor?.title ?? running?.localizedName,
                message: running == nil ? String(localized: "This application has quit") : String(localized: "No windows open"),
                icon: icon ?? running?.icon
            )
        case .window:
            return Self(title: descriptor?.title, message: String(localized: "This window has closed"), icon: icon)
        case .display:
            return Self(title: descriptor?.title, message: String(localized: "This display is not available"), icon: icon)
        case .mosaic:
// Unreachable: a mosaic is never one of its own tiles. Said rather than crashed.
            return Self(title: nil, message: String(localized: "Nothing to show"), icon: nil)
        }
    }

/// The compositor knows a tile is empty, not why.
    static func empty(descriptor: CaptureSourceDescriptor?) -> Self {
        Self(
            title: descriptor?.title,
            message: String(localized: "Nothing to show"),
            icon: descriptor?.iconPNGData.flatMap { NSImage(data: $0) }
        )
    }
}
