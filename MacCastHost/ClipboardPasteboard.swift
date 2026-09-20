import AppKit
import RemoteCore
import os

/// The Mac's pasteboard, in the one shape the protocol carries.
///
/// **Only two pasteboard types are worth carrying, and the choice is not "as many as possible".**
/// A pasteboard declares a list of representations of one thing, and the list is the owner's, most
/// preferred first: copy an image out of a browser and it typically offers a picture *and* the
/// page's text, copy a styled paragraph and it offers rich text, plain text and often HTML. Sending
/// all of them would mean the far end choosing which of several truths to paste, and the choice
/// would be the receiver's rather than the user's. Sending the first one that can be carried is
/// what makes the far end paste what was copied.
enum ClipboardPasteboard {
    /// The picture types that will be carried, in preference order for the ones a pasteboard
    /// declares neither of and this has to pick between.
    ///
    /// PNG first because it is the type that travels without conversion when the owner already
    /// has it, and TIFF second because it is what a macOS screenshot actually puts on the
    /// pasteboard. There is no third: a JPEG on the pasteboard is on it as a picture, and a
    /// pasteboard holding one will offer a TIFF or a PNG of it as well.
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    private static let log = Logger(subsystem: "pl.dmq.peering.host", category: "clipboard")

    /// What is on the pasteboard now, or `nil` for a pasteboard holding nothing this carries.
    ///
    /// Must be called on the main thread: `NSPasteboard` is not safe to read from anywhere else,
    /// which is why the session's callback hops here rather than talking to it directly.
    static func read() -> ClipboardPayload? {
        let board = NSPasteboard.general
        // **The owner's order, not this app's.** `types` is the list the application that owns the
        // pasteboard wrote, most preferred first, and it is that application's answer to what was
        // copied. Walking it is the whole of the decision; a version with a fixed preference order
        // would overrule the app that knows.
        for type in board.types ?? [] {
            if imageTypes.contains(type) {
                guard let png = pngData(from: board, type: type) else { continue }
                guard png.count <= ClipboardLimits.maxImageBytes else {
                    // Refused rather than shrunk. There is no honest way to send half a screenshot
                    // or a degraded one without the user being told, and quietly pasting a worse
                    // picture than the one that was copied is the kind of wrong that is only found
                    // out much later. The user gets nothing, and the log says why.
                    log.notice("""
                        clipboard picture is \(png.count) bytes, over the \(ClipboardLimits.maxImageBytes) limit
                        """)
                    return nil
                }
                return .image(png)
            }
            if type == .string, let text = board.string(forType: .string) {
                // **No separate limit on text.** A long line of text is a payload like any other
                // and is cut up by ``ClipboardTransfer`` if it does not fit one frame, so a
                // figure here would only be a second limit to keep in step with the first, set
                // lower than the protocol needs for no reason a user could be told.
                return .text(text)
            }
        }
        return nil
    }

    /// Puts a payload on the pasteboard, replacing whatever was there.
    static func write(_ payload: ClipboardPayload) {
        let board = NSPasteboard.general
        switch payload.kind {
        case .text:
            guard let text = payload.text else { return }
            board.clearContents()
            board.setString(text, forType: .string)
        case .image:
            // A picture that failed the size check is not written. See ``read()``: the far end
            // would have refused to carry it, so writing it here would put something on the Mac's
            // pasteboard that the phone never actually had.
            guard let png = payload.carriedImage, let image = NSImage(data: png) else { return }
            board.clearContents()
            board.writeObjects([image])
        }
    }

    /// The payload's bytes as PNG, converting whatever the pasteboard actually holds.
    ///
    /// **Converted rather than passed through**, because iOS reads no TIFF. A macOS screenshot is
    /// put on the pasteboard as TIFF and nothing else, so a screenshot copied from the Mac and
    /// sent as itself would arrive at the phone as bytes no image type there can open.
    private static func pngData(from board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Data? {
        guard let data = board.data(forType: type) else { return nil }
        if type == .png { return data }
        guard let representation = NSBitmapImageRep(data: data) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }
}
