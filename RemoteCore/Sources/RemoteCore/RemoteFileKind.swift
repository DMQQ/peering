import Foundation

/// What a file turned out to be, decided by the machine that holds it.
///
/// Three answers rather than two, because the two that are not text are shown by different things:
/// a raster image decodes into a `UIImage` and an SVG goes through a web view. An SVG is text on the
/// wire and a picture on the screen, so the client cannot work the split out from the name; only the
/// end that looked at it can say which one it is.
///
/// There is no `binary` case: a file that is none of these is a refusal, which
/// ``sniff(prefix:path:)`` returning nothing shows.
public enum RemoteFileKind: String, Codable, Equatable, Sendable {
    /// Bytes meant to be read, wrapped or scrolled, and possibly edited.
    case text
    /// A picture the phone can decode itself.
    case image
    /// A picture that arrives as text and is drawn by a web view.
    case svg

    /// Whether the phone draws this rather than reads it.
    ///
    /// The question the size caps are actually asking: a file being looked at is worth far more bytes
    /// than one being read a line at a time.
    public var isDrawn: Bool { self != .text }
}

extension RemoteFileKind {
    /// The longest prefix ``RemoteFileKind/sniff(prefix:path:)`` will look at.
    ///
    /// Eight kilobytes, comfortably past the furthest magic number in the table below: the ISO base
    /// media brands sit at offset eight and nothing here reaches past sixteen.
    public static let probeBytes = 8 * 1024

    /// Which kind a file is, or nothing if it is neither text nor a picture this can show.
    ///
    /// `prefix` is the head of the file, up to ``probeBytes`` of it, and `path` is the name it was
    /// found under. Both are needed: every raster format announces itself in its first bytes, and an
    /// SVG announces itself only in its name, because at the byte level it is XML and so is a plist.
    ///
    /// Contents are asked first and the name second, so a `.png` that holds text is a text file.
    public static func sniff(prefix: Data, path: String) -> RemoteFileKind? {
        if isRaster(prefix) { return .image }

        // An empty file is text with nothing in it, answered here rather than by the loop below,
        // which cannot tell an empty file from one it trimmed all the way down.
        if prefix.isEmpty { return .text }

        // Everything below here is text or nothing: no NUL byte near the start, and what is left
        // still has to decode.
        guard !prefix.prefix(probeBytes).contains(0) else { return nil }
        var head = prefix
        var dropped = 0
        while dropped < 3, String(data: head, encoding: .utf8) == nil, !head.isEmpty {
            head = head.dropLast()
            dropped += 1
        }
        // Trimming everything away means the bytes were never text at all. The window is three bytes
        // wide to rescue a character cut in half by the read cap.
        guard let beginning = String(data: head, encoding: .utf8), !head.isEmpty else { return nil }

        if (path as NSString).pathExtension.lowercased() == "svg" { return .svg }
        // The same file found without its name, as when a path came from a link. Only the head is
        // searched, so this cannot be a document that merely mentions SVG further in.
        if beginning.prefix(512).contains("<svg") { return .svg }

        return .text
    }

    /// Whether the head of the file carries one of the raster magic numbers.
    ///
    /// The formats are exactly the ones ImageIO decodes on both platforms this app ships to: PNG,
    /// JPEG, GIF, TIFF in both byte orders, BMP, WebP, and the HEIF family including AVIF.
    private static func isRaster(_ prefix: Data) -> Bool {
        func matches(_ offset: Int, _ bytes: [UInt8]) -> Bool {
            guard prefix.count >= offset + bytes.count else { return false }
            let start = prefix.index(prefix.startIndex, offsetBy: offset)
            return Array(prefix[start..<prefix.index(start, offsetBy: bytes.count)]) == bytes
        }

        // PNG: the eight-byte signature.
        if matches(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        // JPEG, whose third byte is the start of whichever marker comes first.
        if matches(0, [0xFF, 0xD8, 0xFF]) { return true }
        // GIF, spelled out, so 87a and 89a both land.
        if matches(0, Array("GIF8".utf8)) { return true }
        // TIFF, little-endian and big-endian.
        if matches(0, [0x49, 0x49, 0x2A, 0x00]) { return true }
        if matches(0, [0x4D, 0x4D, 0x00, 0x2A]) { return true }
        // BMP, which is the whole of its test: the size field that follows is not checked, because a
        // wrong guess here shows a broken picture, which is what an unchecked BMP would do anyway.
        if matches(0, Array("BM".utf8)) { return true }
        // WebP: a RIFF container that says so at offset eight.
        if matches(0, Array("RIFF".utf8)), matches(8, Array("WEBP".utf8)) { return true }
        // HEIF and AVIF: an ISO base media file whose brand is one of the still-picture ones.
        // `mif1` and `msf1` are the generic image brands, and a camera's HEIC usually carries
        // `heic` as its compatible brand rather than its major one, so every still-picture brand is
        // listed rather than only the major one.
        if matches(4, Array("ftyp".utf8)) {
            for brand in ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs",
                          "mif1", "msf1", "avif"] where matches(8, Array(brand.utf8)) {
                return true
            }
        }
        return false
    }
}
