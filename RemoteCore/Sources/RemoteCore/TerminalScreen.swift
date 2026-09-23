import Foundation

/// A minimal terminal screen: a grid of characters, and a cursor that escape sequences move.
///
/// ``TerminalTextSanitizer`` renders a byte stream *linearly* — it strips the escape sequences and
/// appends whatever text is left over — so a program that draws its screen by positioning a cursor
/// and overwriting cells has its whole picture reflowed into a couple of mangled lines. `htop` is
/// the case that makes it obvious: its frames arrive as one long smear of text. A full-screen
/// program is only renderable by something that has a cursor to move and cells to overwrite, which
/// is what this is.
///
/// It is not a terminal. There is no scrolling region, no origin mode, no wide-character handling
/// beyond one `Character` per cell, and no DEC line-drawing. What it has is the part that drawing a
/// screen actually depends on. The trade is deliberate: a smaller thing that renders `htop`
/// correctly beats a larger one that renders slightly more of `vim`.
///
/// The character attributes it does keep are the ones that are *colour*: the foreground, the
/// background, bold and dim, per cell, in ``styled``. The rest of SGR — italic, underline, blink,
/// reverse — is read and discarded, which is what an unhandled sequence has always cost here.
public struct TerminalScreen: Sendable {
    /// The shape the screen is drawn on. Set at the start and changed by ``resize(columns:rows:)``,
    /// which is the only thing that may move them.
    public private(set) var columns: Int
    public private(set) var rows: Int

    /// Lines that scrolled off the top, oldest first.
    ///
    /// The text of them: what a line looked like is ``styled``, which keeps the colour along with
    /// it. This is the view for a caller that only wants the words.
    public var scrollback: [String] { history.map { text(of: $0) } }

    private var grid: [[Cell]]

    /// The rows that scrolled off the top, with the styles they were drawn in.
    ///
    /// Cells rather than text, because a row that scrolled away is still a row that was drawn. The
    /// colour a program gave it is part of what it said, and it has to survive the scroll for the
    /// same reason it survives a repaint.
    private var history: [[Cell]] = []

    private var row = 0
    private var column = 0

    /// The rendition the next character is written with: whatever the last SGR sequence left set.
    ///
    /// It is applied *to a cell when that cell is written* and never read back out of one, which is
    /// the whole of why a program can repaint one row without repainting the rest.
    private var attributes = Attributes()

    /// Whether the *next* character wraps before it is written.
    ///
    /// A terminal's cursor does not wrap when it writes the last column; it wraps when it is asked
    /// to write the column past it. The difference is not academic. A full-screen program pads its
    /// rows out to the full width, so wrapping on the write itself would scroll the screen by a row
    /// every time the bottom-right cell is drawn — a row of the frame lost on every refresh, which
    /// looks like a rendering fault and is one.
    private var pendingWrap = false

    /// Whether the alternate screen is up.
    private var alternate = false

    private var parser = Parser.ground
    /// The parameter bytes of the CSI sequence being read. Nothing is interpreted until the final
    /// byte says what the numbers mean, so they are kept raw — the `?` of `CSI ?1049h` has to
    /// survive that long to be recognisable as a private marker rather than a value.
    private var parameters: [UInt8] = []
    private var utf8 = UTF8Accumulator()

    /// How many parameter bytes are kept. Every sequence that means anything to this screen has a
    /// handful of digits in it, so a longer run is a malformed stream; the reason to stop reading
    /// is that a `CSI` followed by a megabyte of digits then costs nothing to skip.
    private static let parameterLimit = 32

    /// The largest value a parameter reads as. `CSI 99999999 H` must not be able to make the screen
    /// do arithmetic it regrets: the number is clamped here and clamped again against the grid.
    private static let parameterCeiling = 9999

    /// How many mode numbers are read out of one set or reset. A program sends one; a malformed
    /// sequence sends as many as it likes, and the rest are ignored.
    private static let modeLimit = 8

    /// The width of a tab stop. Eight is what everything has used since terminals were teletypes.
    private static let tabWidth = 8

    public init(columns: Int = 80, rows: Int = 24) {
        // A grid of zero is not a screen, and every piece of arithmetic below assumes one that can
        // hold at least a character.
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.grid = Array(repeating: Array(repeating: Cell(), count: self.columns), count: self.rows)
    }

    /// Changes the shape the screen is drawn on, keeping what is on it.
    ///
    /// **A resize is not a rebuild, and this is the whole of that difference.** A byte stream is a
    /// picture of a screen *at the size it was written for*: a program addresses cells by row and
    /// column and counts lines to move its cursor, so applying what it drew for one shape to
    /// another lands every frame somewhere the program did not put it. A terminal keeps its cells
    /// across a resize and lets the program paint over them, and this does the same: rows past the
    /// new bottom are dropped, columns past the new right are cut, new cells are blank, and the
    /// cursor is brought back inside.
    ///
    /// The scrollback is left exactly as it is. What has scrolled off has already left this screen,
    /// and re-wrapping it for a narrower one would be a second, invisible re-layout of the past.
    public mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(1, newColumns)
        let newRows = max(1, newRows)
        guard newColumns != columns || newRows != rows else { return }

        // **A shorter screen scrolls, and that is the part a program notices.** It is what a
        // terminal does when the window is made shorter: the rows that do not fit leave from the
        // bottom, and if the cursor was on one of them the screen moves up until it is back on it.
        // Without that scroll the cursor is left pointing at a row the program believes is
        // somewhere else entirely, and the next write it makes lands a line or two from where it
        // meant to put it. Which is what "the window goes crazy when the keyboard opens" is: the
        // keyboard shortens the log, the log shortens the shell's screen, and every repaint after
        // that is drawn to the wrong row.
        if newRows < rows, row >= newRows {
            for _ in 0..<(row - newRows + 1) {
                let top = grid.removeFirst()
                if !alternate { history.append(top) }
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

    /// Applies bytes to the screen.
    ///
    /// The caller is expected to hand over its whole accumulated buffer rather than each new chunk
    /// — that is how the terminal is rendered today, and it is why this type has to be a pure
    /// function of the bytes it has seen and cheap to rebuild. What outlives a single call is the
    /// state a chunk boundary can land inside: half a UTF-8 character, and half an escape sequence.
    public mutating func feed(_ data: Data) {
        for byte in data {
            consume(byte)
        }
    }

    /// The screen as it looks right now, with trailing blank rows removed.
    ///
    /// The grid is fixed at `rows` and is almost always mostly empty, so the blanks at the bottom
    /// are an artefact of its size rather than of anything a program drew. Blanks *between* rows
    /// are kept: a program that leaves a gap means it. A blank with a colour of its own is not one
    /// of these blanks — that is a bar, and it is drawn.
    public var visible: [String] {
        var lines = grid.map { text(of: $0) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Everything, in order: what scrolled off the top, then what is on screen, in runs.
    ///
    /// The same lines as ``visible``, each cut into runs of one rendition, and each carrying its
    /// classification. Coalescing is not a nicety: a frame of `htop` is a couple of thousand
    /// cells, and runs of one character each would be a couple of thousand pieces of text for a
    /// view to lay out again on every chunk that arrives.
    public var styled: [TerminalStyledLine] {
        var rows = grid.map(styledLine)
        // Trailing blank rows are an artefact of the grid's size rather than of anything a program
        // drew, and are dropped the same way `visible` drops them — by the same rule, so the two
        // cannot disagree about how many lines there are.
        while rows.last?.runs.isEmpty == true { rows.removeLast() }
        return history.map(styledLine) + rows
    }

    /// Everything, in order: what scrolled off the top, then what is on screen.
    ///
    /// Derived from ``styled`` so the two cannot disagree — the text of a line is its runs joined
    /// back together — which is what keeps this working unchanged for a caller that wants the words
    /// and not the colour.
    ///
    /// The classification is the terminal's own — ``TerminalTextSanitizer/kind(of:)`` — applied to
    /// a grid row instead of a stream line, so a failure that lands in a cell is coloured the same
    /// way it would have been had it been printed.
    public var lines: [TerminalTextSanitizer.Line] {
        styled.map { TerminalTextSanitizer.Line(text: $0.text, kind: $0.kind) }
    }

    // MARK: - The parser

    private enum Parser {
        case ground
        /// One byte past an escape.
        case escape
        /// Inside a control sequence: parameters, then a final byte.
        case csi
        /// Inside an operating system command or a device control string, whose payload is skipped
        /// rather than collected. Nothing here wants a window title.
        case string
        /// One byte of a sequence being consumed and discarded.
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
            // BEL ends the common form of an operating system command, and ESC opens the two-byte
            // terminator that ends the other.
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
            // A second escape replaces the first rather than starting a sequence that prints the
            // byte after it.
            break
        case UInt8(ascii: "["):
            parameters.removeAll(keepingCapacity: true)
            parser = .csi
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            parser = .string
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "/"):
            // A charset designation takes one more byte. `tput sgr0` and anything that resets a
            // terminal emits one, and the `B` that follows it is not text.
            parser = .discard
        default:
            // Every other escape is a single byte — saved cursors, keypad modes, index and reverse
            // index. Ignoring them is the conservative half of the trade; the part that matters is
            // that the printer never sees them.
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
            // Intermediates, of which no sequence this screen implements has any.
            break
        default:
            // Something that cannot appear inside a sequence: a control byte, or the tail of a
            // buffer that was cut mid-escape. The sequence ends here and this byte is handled for
            // what it is, instead of being swallowed along with the rest of the stream.
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
            // Row first, then column, both one-based, and a missing one means the first.
            place(row: offset(0) - 1, column: offset(1) - 1)
        case UInt8(ascii: "J"):
            eraseDisplay(mode: mode(0))
        case UInt8(ascii: "K"):
            eraseLine(mode: mode(0))
        case UInt8(ascii: "m"):
            selectGraphicRendition()
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            // Modes are mostly how a program asks for things this screen does not have — bracketed
            // paste, key encoding, origin mode — and ignoring them is the whole of the answer. The
            // alternate screen is the exception, and it is private: `CSI 1049h` is not the same
            // request as `CSI ?1049h` and only the latter is honoured.
            if parameters.first == UInt8(ascii: "?") {
                setModes(enabled: byte == UInt8(ascii: "h"))
            }
        default:
            // The scrolling region (`r`), tab stops, the device reports and the rest: nothing this
            // screen draws. Ignored, which is the point — an unhandled sequence must cost nothing
            // rather than arrive as text.
            break
        }
    }

    /// The `index`-th parameter, read out of the raw bytes.
    ///
    /// Anything that is not a digit ends the number, which is what keeps a private marker like the
    /// `?` of `CSI ?1049h` out of the value while still letting a sequence with no parameters at
    /// all read as its own default. The accumulation clamps as it goes, so a parameter too long to
    /// be an `Int` is a large number rather than a trap.
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
                // A sub-parameter separator, or a private marker. Neither is a value.
                break
            }
        }
        return field == index && digits ? value : fallback
    }

    /// A cursor-movement parameter: one-based, and a missing, unreadable or zero one reads as one —
    /// `CSI 0 A` moves up a line the same way `CSI A` does.
    private func offset(_ index: Int) -> Int {
        max(1, number(index, or: 1))
    }

    /// An erase parameter, where zero is a value rather than a missing one.
    private func mode(_ index: Int) -> Int {
        number(index, or: 0)
    }

    private mutating func setModes(enabled: Bool) {
        for index in 0..<Self.modeLimit {
            let code = number(index, or: -1)
            guard code >= 0 else { return }
            switch code {
            // The three private modes that mean the same thing. Which one a program picks depends
            // on which terminal its terminfo entry was written against, and they differ only in
            // whether the cursor is saved, which is a distinction this screen does not draw.
            case 47, 1047, 1049:
                alternateScreen(enabled)
            default:
                break
            }
        }
    }

    // MARK: - What the sequences do

    /// Puts the cursor somewhere, clamped to the screen.
    ///
    /// The clamping is the defence against a parameter that means nothing: `CSI 99999999 H` lands
    /// in the bottom-right corner instead of asking for a grid that does not exist, and a movement
    /// off the front edge stops at the edge instead of running off it.
    private mutating func place(row newRow: Int, column newColumn: Int) {
        row = min(max(newRow, 0), rows - 1)
        column = min(max(newColumn, 0), columns - 1)
        pendingWrap = false
    }

    /// Blanks a span of a row.
    ///
    /// The cells go back to the *default* rendition rather than the current one. A program erases
    /// with whatever pen it happens to be holding — `htop` draws a row and then `CSI K`s the rest
    /// of it away while still wearing that row's colour — so erasing to the current pen would
    /// leave the colour behind in cells that are meant to be empty, and the frame after the next
    /// refresh would be drawn over the tint of the one before it.
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
            // The one that reaches into the history as well, which is how a program clears what it
            // printed before it started drawing. Treating it as a plain screen clear would leave the
            // wrong thing in the terminal.
            history.removeAll()
            clearScreen()
        default:
            break
        }
    }

    private mutating func clearScreen() {
        grid = Array(repeating: blankRow, count: rows)
        place(row: 0, column: 0)
    }

    /// The alternate screen: a full-screen program's own blank page.
    ///
    /// Entering it clears the grid and leaving clears the grid again, because the point of the mode
    /// is that the program's picture is not part of the session. That is what makes `htop` vanish on
    /// exit rather than leaving its last frame where it was drawn, and it is why rows that scroll off
    /// while it is up are dropped instead of being added to ``scrollback``: they are not output, they
    /// are one frame of something that is about to end.
    private mutating func alternateScreen(_ enabled: Bool) {
        // Programs re-assert the mode on every refresh, and clearing on each assertion would erase
        // the frame that was just drawn.
        guard enabled != alternate else { return }
        alternate = enabled
        // The pen goes back to the default with the screen it was drawing on. The colour belongs
        // to a program that is leaving; whatever prints next — a shell prompt, the next command —
        // starts from the terminal's own colours rather than inheriting a full-screen program's.
        attributes = Attributes()
        clearScreen()
    }

    // MARK: - Colour

    /// Applies an SGR sequence — `CSI … m` — to the pen the next characters are written with.
    ///
    /// The parameters are read as a list of numbers rather than walked as a run of bytes, because
    /// that is the only way the extended colours come out right: `38;5;208` is *one* colour written
    /// as three parameters, and a reader that took the `38` and moved on would read the `5` as
    /// blink, the `208` as a code of its own, and every parameter after them shifted by two. What
    /// the numbers mean is decided together or not at all.
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
                // Normal intensity, which cancels both of the two above and nothing else.
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
                // The bright half of the palette, which is the eight above plus eight: the
                // sixteen a program can name with `31` and `91` are entries 0–15 of the 256.
                attributes.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107:
                attributes.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48:
                let extended = Self.extendedColour(fields, at: index - 1)
                // The parameters the colour used are consumed whether or not this screen draws
                // it. They belong to the colour: `38;5;999` is one colour that is out of range,
                // not three codes, and the next real code is the one after it.
                index += extended.consumed - 1
                guard let style = extended.style else { break }
                if code == 38 {
                    attributes.foreground = style
                } else {
                    attributes.background = style
                }
            default:
                // Italic, underline, blink, reverse, the fonts, the ideograms, an underline
                // colour: renditions this screen does not draw. Ignoring them is the whole of the
                // answer to them, and it is safe to ignore them *here* — the list has already
                // been split into parameters, so a code nobody knows cannot make the numbers
                // after it mean something else.
                break
            }
        }
    }

    /// The SGR parameter list, split into one list of numbers per parameter.
    ///
    /// A `;` separates parameters and a `:` separates the sub-parameters of one — the two ways the
    /// extended colours are written, `38;5;208` and `38:5:208` — and both come out of here as the
    /// numbers they are, which is what lets the two be read by the same code.
    ///
    /// An empty field is a zero, which is what makes a bare `CSI m` a reset: a program that resets
    /// the pen writes the `0` or leaves it out, and to a terminal the two say the same thing.
    ///
    /// Anything else — the `?` of a private mode, a marker, a byte of a buffer that was cut
    /// mid-sequence — is not a number, and the sequence is dropped whole rather than half-read.
    /// Guessing where a malformed list meant to resume is how a colour ends up painting the rest
    /// of the screen.
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
                // A missing number is a zero rather than nothing at all: `CSI 1;;31 m` is a reset
                // between the two, exactly as `CSI 1;0;31 m` is.
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

    /// The colour a `38` or `48` names, and how many parameters it took to name it.
    ///
    /// Both forms arrive here and leave as the same list of numbers — the code, the type, then the
    /// values — so `38;5;208` and `38:5;208` differ only in the count that comes back. The count is
    /// in parameters and is returned even when the colour is not drawn, because that is what the
    /// caller needs to know to step over the whole colour instead of landing in the middle of it.
    private static func extendedColour(
        _ fields: [[Int]], at start: Int
    ) -> (consumed: Int, style: TerminalStyle?) {
        guard start < fields.count else { return (1, nil) }
        var numbers = fields[start]
        var consumed = 1
        if numbers.count == 1 {
            // The `;` form: the code is one parameter, the type another, and the values after it.
            // How many values there are is fixed by the type — `5` takes one and `2` takes three —
            // and the type has to be read before the end of the colour can be, since the end of
            // the colour is where the next code starts.
            guard start + 1 < fields.count, fields[start + 1].count == 1 else { return (1, nil) }
            let total = fields[start + 1][0] == 2 ? 5 : fields[start + 1][0] == 5 ? 3 : 0
            // A `38` naming something that is not one of the two extended colours. Nothing more
            // belongs to it, so nothing more is consumed.
            guard total > 0 else { return (1, nil) }
            while numbers.count < total {
                // A sequence that stopped in the middle of its colour, which is what a read cut
                // between two chunks looks like. There is nothing left to misread.
                guard start + consumed < fields.count, fields[start + consumed].count == 1 else {
                    return (consumed, nil)
                }
                numbers.append(fields[start + consumed][0])
                consumed += 1
            }
        }
        return (consumed, colour(of: numbers))
    }

    /// The colour a list of extended-colour numbers names, or `nil` for one this screen does not
    /// draw.
    ///
    /// Read from the end, which is what makes the two forms agree: `38;5;n` and `38:5;n` both end
    /// in the palette entry, and `38;2;r;g;b` and `38:2;r;g;b` both end in the three components.
    /// That also survives the colour space the standard allows between the type and the values,
    /// which is a number a terminal has no use for and no reason to trip over.
    private static func colour(of numbers: [Int]) -> TerminalStyle? {
        guard numbers.count >= 2 else { return nil }
        switch numbers[1] {
        case 5:
            guard numbers.count >= 3, let entry = numbers.last.flatMap({ UInt8(exactly: $0) }) else {
                return nil
            }
            return .indexed(entry)
        case 2:
            // Three components and no fewer. A sequence that stopped after two of them has lost
            // the last one, and taking the three it has would read the type — the `2` — as the red
            // channel of a colour nobody asked for.
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

    /// Moves the cursor down a row, scrolling if it is already on the last one.
    private mutating func advance() {
        guard row == rows - 1 else {
            row += 1
            return
        }
        let top = grid.removeFirst()
        // The whole row, not its text: the colour it was drawn in scrolls into the history with
        // it. Rows that scroll off while the alternate screen is up are dropped instead — they are
        // one frame of something that is about to end, and none of them is output.
        if !alternate { history.append(top) }
        grid.append(blankRow)
    }

    private mutating func control(_ byte: UInt8) {
        switch byte {
        case 0x0D:
            place(row: row, column: 0)
        case 0x0A:
            // A line feed moves down and does nothing else: a shell's output arrives as CRLF, so
            // the pair is what returns to the left margin, and a program that asks for only the
            // next row gets only the next row. Also resetting the column here would be invisible
            // on a shell's output and would fold a full-screen program's drawing back against the
            // left edge.
            pendingWrap = false
            advance()
        case 0x08:
            place(row: row, column: column - 1)
        case 0x09:
            place(row: row, column: (column / Self.tabWidth + 1) * Self.tabWidth)
        default:
            // BEL, vertical tab, form feed, DEL: things a terminal is asked to do that are not
            // drawing.
            break
        }
    }

    /// Where a row stops being worth drawing: the index just past its last cell that is not a
    /// blank.
    ///
    /// Every cell to the right of what a program wrote is a space, and a full-screen program fills
    /// the width on purpose, so the padding is most of the grid. Trimming it is what makes a row
    /// readable, and what makes `visible` comparable to the thing that was drawn.
    ///
    /// Only an *uncoloured* space is padding, which is the one thing styles change about this.
    /// A space is how a program draws a bar — `htop`'s meters are runs of coloured blank cells —
    /// and cutting those off the end of a row would erase what was drawn, not the padding around
    /// it. Bold and dim do not keep a blank: they are not visible on one.
    private func drawnLength(of row: [Cell]) -> Int {
        var end = row.count
        while end > 0, row[end - 1].isBlank { end -= 1 }
        return end
    }

    /// A row as text, with the blanks it was padded out to removed.
    private func text(of row: [Cell]) -> String {
        String(row[0..<drawnLength(of: row)].map(\.character))
    }

    /// A row cut into runs of one rendition each.
    ///
    /// Consecutive cells with the same rendition become one run, so the cost of a row is set by how
    /// many times a program changed colour across it and not by how wide it is. A row that was
    /// never coloured is a single run, which is what most rows of most output are.
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

    /// Whether a scalar that decoded cleanly is still a control rather than text.
    ///
    /// The eight-bit controls arrive as well-formed scalars — U+009B is `CSI` to a terminal that
    /// speaks C1 — and printing one would put an invisible character in the middle of the screen.
    private func isEightBitControl(_ scalar: Unicode.Scalar) -> Bool {
        (0x80...0x9F).contains(scalar.value)
    }
}

/// The rendition a cell was written with.
///
/// Held per cell and never consulted as "the current one" again, which is the difference between a
/// screen a program can repaint and one it can only overdraw.
private struct Attributes: Sendable, Equatable {
    var foreground: TerminalStyle = .default
    var background: TerminalStyle = .default
    var bold = false
    var dim = false
}

/// One cell of the grid: the character in it, and how it was drawn.
private struct Cell: Sendable, Equatable {
    var character: Character = " "
    var attributes = Attributes()

    /// Whether the cell draws as nothing: a space with no colour of its own.
    ///
    /// A coloured blank is not blank in this sense, which is the point of asking — a program draws
    /// a bar out of coloured spaces, and a row's padding is uncoloured ones. Bold and dim do not
    /// keep a blank: neither of them is visible on a space with the default colours.
    var isBlank: Bool {
        character == " "
            && attributes.foreground == .default
            && attributes.background == .default
    }
}

/// Enough of a UTF-8 decoder to survive a character split across two reads.
///
/// A read can end in the middle of a character, so the bytes of an unfinished one are held until
/// the bytes that finish it arrive. Without this the lead byte of `é` would either be dropped or
/// printed as a replacement character in the middle of a word.
private struct UTF8Accumulator {
    private var bytes: [UInt8] = []

    /// The scalar a byte completed, or `nil` if it only continued one.
    mutating func append(_ byte: UInt8) -> Unicode.Scalar? {
        // The common case, and the one worth not paying for.
        if bytes.isEmpty, byte < 0x80 { return Unicode.Scalar(byte) }
        bytes.append(byte)
        guard bytes.count >= Self.length(of: bytes[0]) else { return nil }
        defer { bytes.removeAll(keepingCapacity: true) }
        let string = String(decoding: bytes, as: UTF8.self)
        // One scalar back means the sequence was well formed. Anything else — a bad continuation
        // byte, an overlong form, a lead byte with nothing behind it — is a replacement character,
        // which is a printable answer to bytes that say nothing.
        guard let scalar = string.unicodeScalars.first, string.unicodeScalars.count == 1 else {
            return "\u{FFFD}"
        }
        return scalar
    }

    /// How many bytes a sequence starting with this byte claims.
    ///
    /// A byte that cannot start one claims one, so a stray continuation byte is consumed rather
    /// than stalling the decoder for the rest of the stream.
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
