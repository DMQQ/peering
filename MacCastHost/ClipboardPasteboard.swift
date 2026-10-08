import AppKit
import RemoteCore
import os

/// Carries only the first pasteboard type that can be carried, in the owner order, so the far end pastes what was copied.
enum ClipboardPasteboard {
    /// PNG first (travels unconverted), TIFF second (what a macOS screenshot puts on the pasteboard).
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    private static let log = Logger(subsystem: "pl.dmq.peering.host", category: "clipboard")

    /// Must be called on the main thread: `NSPasteboard` is not safe to read from anywhere else,
    /// which is why the session's callback hops here rather than talking to it directly.
    static func read() -> ClipboardPayload? {
        let board = NSPasteboard.general
        // The owner order, not a fixed preference: the app that owns the pasteboard knows what was copied.
        for type in board.types ?? [] {
            if imageTypes.contains(type) {
                guard let png = pngData(from: board, type: type) else { continue }
                guard png.count <= ClipboardLimits.maxImageBytes else {
                    // Refused rather than shrunk: silently pasting a degraded picture is worse than nothing.
                    log.notice("""
                        clipboard picture is \(png.count) bytes, over the \(ClipboardLimits.maxImageBytes) limit
                        """)
                    return nil
                }
                return .image(png)
            }
            if type == .string, let text = board.string(forType: .string) {
                // No text limit here: ClipboardTransfer splits long text across frames.
                return .text(text)
            }
        }
        return nil
    }

    static func write(_ payload: ClipboardPayload) {
        let board = NSPasteboard.general
        switch payload.kind {
        case .text:
            guard let text = payload.text else { return }
            board.clearContents()
            board.setString(text, forType: .string)
        case .image:
            // A picture that failed the size check is not written, matching what the far end would carry.
            guard let png = payload.carriedImage, let image = NSImage(data: png) else { return }
            board.clearContents()
            board.writeObjects([image])
        }
    }

    /// Converted because iOS reads no TIFF, and a macOS screenshot is TIFF only.
    private static func pngData(from board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Data? {
        guard let data = board.data(forType: type) else { return nil }
        if type == .png { return data }
        guard let representation = NSBitmapImageRep(data: data) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }
}
