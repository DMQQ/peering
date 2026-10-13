import Foundation

extension TerminalScreen {
    enum Parser {
        case ground
        case escape
        case csi
        case string
        case discard
    }

    mutating func consume(_ byte: UInt8) {
        switch parser {
        case .ground:
            if byte == 0x1B {
                parser = .escape
            } else if byte < 0x20 || byte == 0x7F {
                control(byte)
            } else if let scalar = utf8.append(byte), !isEightBitControl(scalar) {
                put(Character(scalar))
            }
        case .escape:
            escape(byte)
        case .csi:
            csi(byte)
        case .string:
            if byte == 0x07 {
                parser = .ground
            } else if byte == 0x1B {
                parser = .discard
            }
        case .discard:
            parser = .ground
        }
    }

    mutating func escape(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            break
        case UInt8(ascii: "["):
            parameters.removeAll(keepingCapacity: true)
            parser = .csi
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            parser = .string
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "/"):
            parser = .discard
        default:
            parser = .ground
        }
    }

    mutating func csi(_ byte: UInt8) {
        switch byte {
        case 0x40...0x7E:
            apply(final: byte)
            parser = .ground
        case 0x30...0x3F:
            guard parameters.count < Self.parameterLimit else { return }
            parameters.append(byte)
        case 0x20...0x2F:
            break
        default:
            // A control byte or a buffer cut mid-escape ends the sequence and is handled as itself.
            parser = .ground
            consume(byte)
        }
    }

    mutating func apply(final byte: UInt8) {
        switch byte {
        case UInt8(ascii: "A"):
            place(row: row - offset(0), column: column)
        case UInt8(ascii: "B"), UInt8(ascii: "e"):
            place(row: row + offset(0), column: column)
        case UInt8(ascii: "C"), UInt8(ascii: "a"):
            place(row: row, column: column + offset(0))
        case UInt8(ascii: "D"):
            place(row: row, column: column - offset(0))
        case UInt8(ascii: "E"):
            place(row: row + offset(0), column: 0)
        case UInt8(ascii: "F"):
            place(row: row - offset(0), column: 0)
        case UInt8(ascii: "G"), UInt8(ascii: "`"):
            place(row: row, column: offset(0) - 1)
        case UInt8(ascii: "d"):
            place(row: offset(0) - 1, column: column)
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            place(row: offset(0) - 1, column: offset(1) - 1)
        case UInt8(ascii: "J"):
            eraseDisplay(mode: mode(0))
        case UInt8(ascii: "K"):
            eraseLine(mode: mode(0))
        case UInt8(ascii: "m"):
            selectGraphicRendition()
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            // The alternate screen is the one mode honoured, and only private: `CSI 1049h` is not `CSI ?1049h`.
            if parameters.first == UInt8(ascii: "?") {
                setModes(enabled: byte == UInt8(ascii: "h"))
            }
        default:
            // Unhandled sequences must cost nothing rather than arrive as text.
            break
        }
    }

    /// Anything that is not a digit ends the number (keeping the `?` out); clamped as it accumulates so an over-long parameter cannot trap.
    func number(_ index: Int, or fallback: Int) -> Int {
        var field = 0
        var value = 0
        var digits = false
        for byte in parameters {
            switch byte {
            case 0x30...0x39:
                value = min(value * 10 + Int(byte - 0x30), Self.parameterCeiling)
                digits = true
            case UInt8(ascii: ";"):
                if field == index { return digits ? value : fallback }
                field += 1
                value = 0
                digits = false
            default:
                break
            }
        }
        return field == index && digits ? value : fallback
    }

    /// One-based; missing, unreadable or zero reads as one, so `CSI 0 A` equals `CSI A`.
    func offset(_ index: Int) -> Int {
        max(1, number(index, or: 1))
    }

    func mode(_ index: Int) -> Int {
        number(index, or: 0)
    }

    mutating func setModes(enabled: Bool) {
        for index in 0..<Self.modeLimit {
            let code = number(index, or: -1)
            guard code >= 0 else { return }
            switch code {
            case 47, 1047, 1049:
                alternateScreen(enabled)
            default:
                break
            }
        }
    }
}
