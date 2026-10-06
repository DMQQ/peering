import Foundation

/// A minimal terminal screen: a grid of characters and a cursor that escape sequences move, for programs that draw by positioning (which ``TerminalTextSanitizer``'s linear rendering mangles).
///
/// It is not a terminal: no scrolling region, no origin mode, no wide-character handling beyond one
/// `Character` per cell, and no DEC line-drawing.
public struct TerminalScreen: Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int

    public var scrollback: [String] { history.map { text(of: $0) } }

    private var grid: [[Cell]]

    /// Cells rather than text, so colour survives the scroll.
    private var history: [[Cell]] = []

    /// ``history`` cut into runs; a scrolled-off row never changes, so it is styled once as it leaves.
    private var styledHistory: [TerminalStyledLine] = []

    /// Bounded on this side's cell copy; the wire's byte buffer does not bound it.
    private static let scrollbackLimit = 2_000

    /// Slack before the history is cut back, so the copy is not paid on every scrolled row.
    private static let scrollbackSlack = 256

    private var row = 0
    private var column = 0

    /// The rendition the next character is written with. Never read back, so a program can repaint one row without the rest.
    private var attributes = Attributes()

    /// A terminal wraps when asked to write past the last column, not on writing it; otherwise a program padding rows to full width would scroll on every bottom-right write.
    private var pendingWrap = false

    private var alternate = false

    private var parser = Parser.ground
    /// Raw until the final byte says what they mean: the `?` of `CSI ?1049h` must stay recognisable.
    private var parameters: [UInt8] = []
    private var utf8 = UTF8Accumulator()

    /// A longer run is malformed; stopping the read makes `CSI` plus a megabyte of digits cost nothing.
    private static let parameterLimit = 32

    /// Clamps a parameter so `CSI 99999999 H` cannot overflow; clamped again against the grid.
    private static let parameterCeiling = 9999

    private static let modeLimit = 8

    private static let tabWidth = 8

    public init(columns: Int = 80, rows: Int = 24) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.grid = Array(repeating: Array(repeating: Cell(), count: self.columns), count: self.rows)
    }

    /// Keeps the cells and lets the program paint over them (a byte stream is a picture at the size it was written for); scrollback is not re-wrapped.
    public mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(1, newColumns)
        let newRows = max(1, newRows)
        guard newColumns != columns || newRows != rows else { return }

        // A shorter screen scrolls to bring the cursor back; otherwise later writes land rows off.
        if newRows < rows, row >= newRows {
            for _ in 0..<(row - newRows + 1) {
                let top = grid.removeFirst()
                record(top)
                grid.append(blankRow)
            }
            row = newRows - 1
        }

        grid = (0..<newRows).map { index in
            var cells = index < grid.count ? grid[index] : []
            if cells.count > newColumns {
                cells.removeLast(cells.count - newColumns)
            } else if cells.count < newColumns {
                cells.append(contentsOf: repeatElement(Cell(), count: newColumns - cells.count))
            }
            return cells
        }
        columns = newColumns
        rows = newRows
        row = min(row, newRows - 1)
        column = min(column, newColumns - 1)
        pendingWrap = false
    }

    /// The caller passes its whole accumulated buffer, not each chunk; what survives a call is whatever a chunk boundary can split (half a UTF-8 character or escape sequence).
    public mutating func feed(_ data: Data) {
        for byte in data {
            consume(byte)
        }
    }

    /// Trailing blank rows (an artefact of the fixed grid) are removed; a blank with its own colour is a bar and stays.
    public var visible: [String] {
        var lines = grid.map { text(of: $0) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Scrollback then screen, in runs of one rendition with classification. One run per character would be thousands of text pieces for an `htop` frame.
    public var styled: [TerminalStyledLine] {
        var rows = grid.map(styledLine)
        while rows.last?.runs.isEmpty == true { rows.removeLast() }
        return styledHistory + rows
    }

    /// ``styled`` without the colour, classified with ``TerminalTextSanitizer/kind(of:)`` on grid rows.
    public var lines: [TerminalTextSanitizer.Line] {
        styled.map { TerminalTextSanitizer.Line(text: $0.text, kind: $0.kind) }
    }

    // MARK: - The parser

    private enum Parser {
        case ground
        case escape
        case csi
        case string
        case discard
    }

    private mutating func consume(_ byte: UInt8) {
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

    private mutating func escape(_ byte: UInt8) {
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

    private mutating func csi(_ byte: UInt8) {
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

    private mutating func apply(final byte: UInt8) {
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
    private func number(_ index: Int, or fallback: Int) -> Int {
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
    private func offset(_ index: Int) -> Int {
        max(1, number(index, or: 1))
    }

    private func mode(_ index: Int) -> Int {
        number(index, or: 0)
    }

    private mutating func setModes(enabled: Bool) {
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

    // MARK: - What the sequences do

    /// Clamped to the screen: `CSI 99999999 H` lands bottom-right.
    private mutating func place(row newRow: Int, column newColumn: Int) {
        row = min(max(newRow, 0), rows - 1)
        column = min(max(newColumn, 0), columns - 1)
        pendingWrap = false
    }

    /// Erases to the default rendition, not the current pen, or colour would be left behind in cells meant to be empty.
    private mutating func clear(from start: Int, to end: Int, on row: Int) {
        guard start <= end else { return }
        for index in start...end { grid[row][index] = Cell() }
    }

    private mutating func eraseLine(mode: Int) {
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

    private mutating func eraseDisplay(mode: Int) {
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

    private mutating func clearScreen() {
        grid = Array(repeating: blankRow, count: rows)
        place(row: 0, column: 0)
    }

    /// A full-screen program's own blank page: entering and leaving clear the grid, and rows scrolled off meanwhile are dropped, not added to ``scrollback``.
    private mutating func alternateScreen(_ enabled: Bool) {
        // Programs re-assert the mode on every refresh; clearing each time would erase the frame.
        guard enabled != alternate else { return }
        alternate = enabled
        attributes = Attributes()
        clearScreen()
    }

    // MARK: - Colour

    /// Parameters are read as a list so an extended colour stays one colour: a reader taking `38` alone would read the `5` of `38;5;208` as blink and shift everything after it.
    private mutating func selectGraphicRendition() {
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
    private func sgrParameters() -> [[Int]]? {
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
    private static func extendedColour(
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
    private static func colour(of numbers: [Int]) -> TerminalStyle? {
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

    // MARK: - Drawing

    private var blankRow: [Cell] { Array(repeating: Cell(), count: columns) }

    private mutating func put(_ character: Character) {
        if pendingWrap {
            column = 0
            advance()
            pendingWrap = false
        }
        grid[row][column] = Cell(character: character, attributes: attributes)
        if column == columns - 1 {
            pendingWrap = true
        } else {
            column += 1
        }
    }

    private mutating func advance() {
        guard row == rows - 1 else {
            row += 1
            return
        }
        let top = grid.removeFirst()
        record(top)
        grid.append(blankRow)
    }

    /// Takes a scrolled-off row whole, so its colour goes into the history, keeping it bounded. Dropped while the alternate screen is up.
    private mutating func record(_ scrolled: [Cell]) {
        guard !alternate else { return }
        history.append(scrolled)
        styledHistory.append(styledLine(scrolled))
        guard history.count > Self.scrollbackLimit + Self.scrollbackSlack else { return }
        let excess = history.count - Self.scrollbackLimit
        history.removeFirst(excess)
        styledHistory.removeFirst(excess)
    }

    private mutating func control(_ byte: UInt8) {
        switch byte {
        case 0x0D:
            place(row: row, column: 0)
        case 0x0A:
            // A line feed only moves down: shell output arrives as CRLF, and resetting the column here would fold full-screen drawing against the left edge.
            pendingWrap = false
            advance()
        case 0x08:
            place(row: row, column: column - 1)
        case 0x09:
            place(row: row, column: (column / Self.tabWidth + 1) * Self.tabWidth)
        default:
            break
        }
    }

    /// The index past the last non-blank cell. Only an uncoloured space is padding: a coloured blank is a bar. Bold and dim do not keep a blank.
    private func drawnLength(of row: [Cell]) -> Int {
        var end = row.count
        while end > 0, row[end - 1].isBlank { end -= 1 }
        return end
    }

    private func text(of row: [Cell]) -> String {
        String(row[0..<drawnLength(of: row)].map(\.character))
    }

    /// Consecutive cells of one rendition become one run, so cost follows colour changes rather than width.
    private func styledLine(_ row: [Cell]) -> TerminalStyledLine {
        let end = drawnLength(of: row)
        var runs: [TerminalRun] = []
        var index = 0
        while index < end {
            let attributes = row[index].attributes
            var text = ""
            while index < end, row[index].attributes == attributes {
                text.append(row[index].character)
                index += 1
            }
            runs.append(
                TerminalRun(
                    text: text,
                    foreground: attributes.foreground,
                    background: attributes.background,
                    bold: attributes.bold,
                    dim: attributes.dim
                )
            )
        }
        let line = runs.map(\.text).joined()
        return TerminalStyledLine(runs: runs, kind: TerminalTextSanitizer.kind(of: line))
    }

    /// Eight-bit controls arrive as well-formed scalars (U+009B is `CSI` to a terminal that speaks C1).
    private func isEightBitControl(_ scalar: Unicode.Scalar) -> Bool {
        (0x80...0x9F).contains(scalar.value)
    }
}

/// The rendition a cell was written with; never consulted as the current one, so a program can repaint.
private struct Attributes: Sendable, Equatable {
    var foreground: TerminalStyle = .default
    var background: TerminalStyle = .default
    var bold = false
    var dim = false
}

private struct Cell: Sendable, Equatable {
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
private struct UTF8Accumulator {
    private var bytes: [UInt8] = []

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
    private static func length(of lead: UInt8) -> Int {
        switch lead {
        case ..<0x80: return 1
        case 0xC0...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF7: return 4
        default: return 1
        }
    }
}
