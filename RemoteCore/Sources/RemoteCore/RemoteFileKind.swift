import Foundation

/// Three kinds because rasters decode natively while an SVG (text on the wire, a picture on screen) needs a web view, so only the end that looked can say. No `binary` case: ``sniff(prefix:path:)`` returns nil for a refusal.
public enum RemoteFileKind: String, Codable, Equatable, Sendable {
    case text
    case image
    case svg
    case pdf
    case video

    /// Whether the phone draws this rather than reads it; the size caps depend on it.
    public var isDrawn: Bool { self != .text }
}

extension RemoteFileKind {
    /// The longest prefix ``sniff(prefix:path:)`` looks at, past the furthest magic number (ISO media brands at offset eight).
    public static let probeBytes = 8 * 1024

    /// Which kind a file is, or nil if neither text nor a showable picture. Rasters are recognised by bytes, SVG only by name (at byte level it is XML, like a plist). Contents are asked first, so a `.png` holding text is text.
    public static func sniff(prefix: Data, path: String) -> RemoteFileKind? {
        if isRaster(prefix) { return .image }
        // The spec lets a few stray bytes precede the header, so it is looked for in the first kilobyte rather than at offset zero.
        if prefix.prefix(1024).range(of: Data("%PDF-".utf8)) != nil { return .pdf }
        if isVideo(prefix) { return .video }

        // Answered here because the loop below cannot tell an empty file from one trimmed to nothing.
        if prefix.isEmpty { return .text }

        guard !prefix.prefix(probeBytes).contains(0) else { return nil }
        var head = prefix
        var dropped = 0
        while dropped < 3, String(data: head, encoding: .utf8) == nil, !head.isEmpty {
            head = head.dropLast()
            dropped += 1
        }
        // Trimming to nothing means never text. The three-byte window rescues a character cut by the read cap.
        guard let beginning = String(data: head, encoding: .utf8), !head.isEmpty else { return nil }

        if (path as NSString).pathExtension.lowercased() == "svg" { return .svg }
        // The same file without its name (a path from a link); only the head is searched.
        if beginning.prefix(512).contains("<svg") { return .svg }

        return .text
    }

    /// MP4 and QuickTime: an `ftyp` box (any brand that is not a still picture, those are caught as rasters first) or a movie that opens straight on `moov`, `mdat` or `wide`. Contains NUL bytes, so without this it would be refused as binary.
    private static func isVideo(_ prefix: Data) -> Bool {
        guard prefix.count >= 12 else { return false }
        let box = prefix.dropFirst(4).prefix(4)
        return ["ftyp", "moov", "mdat", "wide"].contains { box.elementsEqual(Array($0.utf8)) }
    }

    /// The formats ImageIO decodes on both platforms.
    private static func isRaster(_ prefix: Data) -> Bool {
        func matches(_ offset: Int, _ bytes: [UInt8]) -> Bool {
            guard prefix.count >= offset + bytes.count else { return false }
            let start = prefix.index(prefix.startIndex, offsetBy: offset)
            return Array(prefix[start..<prefix.index(start, offsetBy: bytes.count)]) == bytes
        }

        if matches(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if matches(0, [0xFF, 0xD8, 0xFF]) { return true }
        if matches(0, Array("GIF8".utf8)) { return true }
        if matches(0, [0x49, 0x49, 0x2A, 0x00]) { return true }
        if matches(0, [0x4D, 0x4D, 0x00, 0x2A]) { return true }
        // BMP: the size field is not checked; a wrong guess just shows a broken picture.
        if matches(0, Array("BM".utf8)) { return true }
        if matches(0, Array("RIFF".utf8)), matches(8, Array("WEBP".utf8)) { return true }
        // HEIF/AVIF: a camera's HEIC often carries `heic` as a compatible brand, not the major one, so every still-picture brand is listed.
        if matches(4, Array("ftyp".utf8)) {
            for brand in ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs",
                          "mif1", "msf1", "avif"] where matches(8, Array(brand.utf8)) {
                return true
            }
        }
        return false
    }
}
