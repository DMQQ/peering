import Foundation

/// The rendition a cell was written with; never consulted as the current one, so a program can repaint.
struct Attributes: Sendable, Equatable {
    var foreground: TerminalStyle = .default
    var background: TerminalStyle = .default
    var bold = false
    var dim = false
}

struct Cell: Sendable, Equatable {
    var character: Character = " "
    var attributes = Attributes()

    /// A space with no colour of its own; a coloured blank is a bar, and bold or dim is not visible on one.
    var isBlank: Bool {
        character == " "
            && attributes.foreground == .default
            && attributes.background == .default
    }
}

/// Survives a character split across two reads.
struct UTF8Accumulator {
    var bytes: [UInt8] = []

    mutating func append(_ byte: UInt8) -> Unicode.Scalar? {
        if bytes.isEmpty, byte < 0x80 { return Unicode.Scalar(byte) }
        bytes.append(byte)
        guard bytes.count >= Self.length(of: bytes[0]) else { return nil }
        defer { bytes.removeAll(keepingCapacity: true) }
        let string = String(decoding: bytes, as: UTF8.self)
        // Anything but one well-formed scalar becomes a replacement character.
        guard let scalar = string.unicodeScalars.first, string.unicodeScalars.count == 1 else {
            return "\u{FFFD}"
        }
        return scalar
    }

    /// A byte that cannot start a sequence claims one, so a stray continuation byte is consumed rather than stalling.
    static func length(of lead: UInt8) -> Int {
        switch lead {
        case ..<0x80: return 1
        case 0xC0...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF7: return 4
        default: return 1
        }
    }
}
