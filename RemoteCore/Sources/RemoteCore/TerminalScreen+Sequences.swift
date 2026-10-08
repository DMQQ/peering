import Foundation

extension TerminalScreen {
    /// Clamped to the screen: `CSI 99999999 H` lands bottom-right.
    mutating func place(row newRow: Int, column newColumn: Int) {
        row = min(max(newRow, 0), rows - 1)
        column = min(max(newColumn, 0), columns - 1)
        pendingWrap = false
    }

    /// Erases to the default rendition, not the current pen, or colour would be left behind in cells meant to be empty.
    mutating func clear(from start: Int, to end: Int, on row: Int) {
        guard start <= end else { return }
        for index in start...end { grid[row][index] = Cell() }
    }

    mutating func eraseLine(mode: Int) {
        switch mode {
        case 1:
            clear(from: 0, to: column, on: row)
        case 0:
            clear(from: column, to: columns - 1, on: row)
        case 2:
            clear(from: 0, to: columns - 1, on: row)
        default:
            break
        }
    }

    mutating func eraseDisplay(mode: Int) {
        switch mode {
        case 1:
            clear(from: 0, to: column, on: row)
            for above in 0..<row { clear(from: 0, to: columns - 1, on: above) }
        case 0:
            clear(from: column, to: columns - 1, on: row)
            for below in (row + 1)..<rows { clear(from: 0, to: columns - 1, on: below) }
        case 2:
            clearScreen()
        case 3:
            history.removeAll()
            styledHistory.removeAll()
            clearScreen()
        default:
            break
        }
    }

    mutating func clearScreen() {
        grid = Array(repeating: blankRow, count: rows)
        place(row: 0, column: 0)
    }

    /// A full-screen program's own blank page: entering and leaving clear the grid, and rows scrolled off meanwhile are dropped, not added to ``scrollback``.
    mutating func alternateScreen(_ enabled: Bool) {
        // Programs re-assert the mode on every refresh; clearing each time would erase the frame.
        guard enabled != alternate else { return }
        alternate = enabled
        attributes = Attributes()
        clearScreen()
    }

    /// Parameters are read as a list so an extended colour stays one colour: a reader taking `38` alone would read the `5` of `38;5;208` as blink and shift everything after it.
    mutating func selectGraphicRendition() {
        guard let fields = sgrParameters() else { return }
        var index = 0
        while index < fields.count {
            let code = fields[index].first ?? 0
            index += 1
            switch code {
            case 0:
                attributes = Attributes()
            case 1:
                attributes.bold = true
            case 2:
                attributes.dim = true
            case 22:
                attributes.bold = false
                attributes.dim = false
            case 30...37:
                attributes.foreground = .indexed(UInt8(code - 30))
            case 40...47:
                attributes.background = .indexed(UInt8(code - 40))
            case 39:
                attributes.foreground = .default
            case 49:
                attributes.background = .default
            case 90...97:
                attributes.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107:
                attributes.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48:
                let extended = Self.extendedColour(fields, at: index - 1)
                // Consumed whether or not drawn: `38;5;999` is one out-of-range colour, not three parameters.
                index += extended.consumed - 1
                guard let style = extended.style else { break }
                if code == 38 {
                    attributes.foreground = style
                } else {
                    attributes.background = style
                }
            default:
                // Renditions this screen does not draw; safe to ignore since the list is already split.
                break
            }
        }
    }

    /// `;` separates parameters and `:` sub-parameters (`38;5;208` and `38:5:208`). An empty field is zero, so a bare `CSI m` resets; anything else (the `?` of a private mode) drops the sequence.
    func sgrParameters() -> [[Int]]? {
        guard !parameters.isEmpty else { return [[0]] }
        var fields: [[Int]] = []
        var field: [Int] = []
        var value = 0
        var digits = false
        for byte in parameters {
            switch byte {
            case 0x30...0x39:
                value = min(value * 10 + Int(byte - 0x30), Self.parameterCeiling)
                digits = true
            case UInt8(ascii: ";"), UInt8(ascii: ":"):
                // A missing number is zero: `CSI 1;;31 m` resets between the two.
                field.append(digits ? value : 0)
                if byte == UInt8(ascii: ";") {
                    fields.append(field)
                    field = []
                }
                value = 0
                digits = false
            default:
                return nil
            }
        }
        field.append(digits ? value : 0)
        fields.append(field)
        return fields
    }

    /// The colour a `38` or `48` names and how many parameters it took. The count is returned even when the colour is not drawn, so the caller can step over it.
    static func extendedColour(
        _ fields: [[Int]], at start: Int
    ) -> (consumed: Int, style: TerminalStyle?) {
        guard start < fields.count else { return (1, nil) }
        var numbers = fields[start]
        var consumed = 1
        if numbers.count == 1 {
            // The `;` form: the type fixes how many values follow (`5` one, `2` three).
            guard start + 1 < fields.count, fields[start + 1].count == 1 else { return (1, nil) }
            let total = fields[start + 1][0] == 2 ? 5 : fields[start + 1][0] == 5 ? 3 : 0
            guard total > 0 else { return (1, nil) }
            while numbers.count < total {
                // Stopped mid-colour, as a read cut between chunks looks.
                guard start + consumed < fields.count, fields[start + consumed].count == 1 else {
                    return (consumed, nil)
                }
                numbers.append(fields[start + consumed][0])
                consumed += 1
            }
        }
        return (consumed, colour(of: numbers))
    }

    /// The colour a list of extended-colour numbers names, or nil if not drawn. Read from the end so both forms agree.
    static func colour(of numbers: [Int]) -> TerminalStyle? {
        guard numbers.count >= 2 else { return nil }
        switch numbers[1] {
        case 5:
            guard numbers.count >= 3, let entry = numbers.last.flatMap({ UInt8(exactly: $0) }) else {
                return nil
            }
            return .indexed(entry)
        case 2:
            // Three components or none: after two, taking three would read the type as red.
            guard numbers.count >= 5 else { return nil }
            let components = numbers.suffix(3).compactMap { UInt8(exactly: $0) }
            guard components.count == 3 else { return nil }
            return .rgb(components[0], components[1], components[2])
        default:
            return nil
        }
    }
}
