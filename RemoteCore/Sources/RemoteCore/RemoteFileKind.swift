import Foundation

/// What a file turned out to be, decided by the machine that holds it.
///
/// Three answers rather than two, because the two that are not text are shown by different things:
/// a raster image decodes straight into a `UIImage`, and an SVG goes through a web view. That
/// second one is also why the split cannot be left to the client to work out from the name — an
/// SVG is text on the wire and a picture on the screen, so the only end that can say which it is
/// is the one that looked at it.
///
/// There is no `binary` case. A file that is none of these is not a fourth kind of preview, it is
/// a refusal, and the two doors that read files already have a sentence for it — see
/// ``sniff(prefix:path:)`` returning nothing.
public enum RemoteFileKind: String, Codable, Equatable, Sendable {
    /// Bytes meant to be read, wrapped or scrolled, and possibly edited.
    case text
    /// A picture the phone can decode itself.
    case image
    /// A picture that arrives as text and is drawn by a web view.
    case svg

    /// Whether the phone draws this rather than reads it.
    ///
    /// The question the size caps are actually asking: a file being *looked at* is worth far more
    /// bytes than one being read a line at a time, and a preview that stops halfway through a
    /// picture is not a smaller picture, it is a broken one.
    public var isDrawn: Bool { self != .text }
}

extension RemoteFileKind {
    /// The longest prefix ``RemoteFileKind/sniff(prefix:path:)`` will look at.
    ///
    /// Eight kilobytes, the same window the NUL probe has always used, and comfortably past the
    /// furthest magic number in the table below: the ISO base media brands sit at offset eight, and
    /// nothing here reaches past sixteen.
    public static let probeBytes = 8 * 1024

    /// Which kind a file is, or nothing if it is neither text nor a picture this can show.
    ///
    /// `prefix` is the head of the file — up to ``probeBytes`` of it — and `path` is the name it
    /// was found under. Both are needed and neither is redundant: every raster format announces
    /// itself in its first bytes, and SVG announces itself only in its name, because at the byte
    /// level an SVG is XML and so is a plist.
    ///
    /// Contents are asked first and the name second, deliberately. A `.png` that holds text is a
    /// text file, and the answer that came from the bytes is the one to give.
    public static func sniff(prefix: Data, path: String) -> RemoteFileKind? {
        if isRaster(prefix) { return .image }

        // An empty file is text with nothing in it, and the panel has a sentence for that already.
        // It is answered here rather than by the loop below, which cannot tell an empty file from
        // one it just finished trimming all the way down.
        if prefix.isEmpty { return .text }

        // Everything below here is text or nothing, so the test that used to be the whole answer
        // is now the gate in front of the last two cases: no NUL byte near the start, and what is
        // left still has to decode.
        guard !prefix.prefix(probeBytes).contains(0) else { return nil }
        var head = prefix
        var dropped = 0
        while dropped < 3, String(data: head, encoding: .utf8) == nil, !head.isEmpty {
            head = head.dropLast()
            dropped += 1
        }
        // Trimming everything away means the bytes were never text at all. The window is three
        // bytes wide to rescue a character cut in half by the read cap, not to empty out a file
        // that never decoded in the first place.
        guard let beginning = String(data: head, encoding: .utf8), !head.isEmpty else { return nil }

        if (path as NSString).pathExtension.lowercased() == "svg" { return .svg }
        // And the same file found without its name, which is the case for a path the browser
        // reached through a link. Only the head is searched, so this cannot be a document that
        // merely mentions SVG somewhere in the middle.
        if beginning.prefix(512).contains("<svg") { return .svg }

        return .text
    }

    /// Whether the head of the file carries one of the raster magic numbers.
    ///
    /// A table rather than a per-format function, because the whole of it is a prefix comparison
    /// and writing six of those out is how the seventh gets the offset wrong. The formats are
    /// exactly the ones ImageIO decodes on both platforms this app ships to: PNG, JPEG, GIF,
    /// TIFF in both byte orders, BMP, WebP, and the HEIF family including AVIF.
    private static func isRaster(_ prefix: Data) -> Bool {
        func matches(_ offset: Int, _ bytes: [UInt8]) -> Bool {
            guard prefix.count >= offset + bytes.count else { return false }
            let start = prefix.index(prefix.startIndex, offsetBy: offset)
            return Array(prefix[start..<prefix.index(start, offsetBy: bytes.count)]) == bytes
        }

        // PNG: the eight-byte signature, which exists precisely so a PNG can be told from
        // anything that merely begins with 0x89.
        if matches(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        // JPEG, whose third byte is the start of whichever marker comes first.
        if matches(0, [0xFF, 0xD8, 0xFF]) { return true }
        // GIF, spelled out, so 87a and 89a both land.
        if matches(0, Array("GIF8".utf8)) { return true }
        // TIFF, little-endian and big-endian.
        if matches(0, [0x49, 0x49, 0x2A, 0x00]) { return true }
        if matches(0, [0x4D, 0x4D, 0x00, 0x2A]) { return true }
        // BMP, which is the whole of its test: two bytes is a short signature, and the size field
        // that follows is not checked because a wrong guess here shows a broken picture, which is
        // the same thing an unchecked BMP would do.
        if matches(0, Array("BM".utf8)) { return true }
        // WebP: a RIFF container that says so at offset eight.
        if matches(0, Array("RIFF".utf8)), matches(8, Array("WEBP".utf8)) { return true }
        // HEIF and AVIF: an ISO base media file whose brand is one of the still-picture ones.
        // `mif1` and `msf1` are the generic image brands, and a HEIC written by a camera usually
        // carries `heic` as its *compatible* brand rather than its major one, so the whole box
        // head is searched rather than the four bytes at offset eight.
        if matches(4, Array("ftyp".utf8)) {
            for brand in ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs",
                          "mif1", "msf1", "avif"] where matches(8, Array(brand.utf8)) {
                return true
            }
        }
        return false
    }
}
