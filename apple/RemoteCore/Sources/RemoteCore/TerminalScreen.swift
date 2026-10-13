import Foundation

/// A minimal terminal screen: a grid of characters and a cursor that escape sequences move, for programs that draw by positioning (which ``TerminalTextSanitizer``'s linear rendering mangles).
///
/// It is not a terminal: no scrolling region, no origin mode, no wide-character handling beyond one
/// `Character` per cell, and no DEC line-drawing.
public struct TerminalScreen: Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int

    public var scrollback: [String] { history.map { text(of: $0) } }

    var grid: [[Cell]]

    /// Cells rather than text, so colour survives the scroll.
    var history: [[Cell]] = []

    /// ``history`` cut into runs; a scrolled-off row never changes, so it is styled once as it leaves.
    var styledHistory: [TerminalStyledLine] = []

    /// Bounded on this side's cell copy; the wire's byte buffer does not bound it.
    static let scrollbackLimit = 2_000

    /// Slack before the history is cut back, so the copy is not paid on every scrolled row.
    static let scrollbackSlack = 256

    var row = 0
    var column = 0

    /// The rendition the next character is written with. Never read back, so a program can repaint one row without the rest.
    var attributes = Attributes()

    /// A terminal wraps when asked to write past the last column, not on writing it; otherwise a program padding rows to full width would scroll on every bottom-right write.
    var pendingWrap = false

    var alternate = false

    var parser = Parser.ground
    /// Raw until the final byte says what they mean: the `?` of `CSI ?1049h` must stay recognisable.
    var parameters: [UInt8] = []
    var utf8 = UTF8Accumulator()

    /// A longer run is malformed; stopping the read makes `CSI` plus a megabyte of digits cost nothing.
    static let parameterLimit = 32

    /// Clamps a parameter so `CSI 99999999 H` cannot overflow; clamped again against the grid.
    static let parameterCeiling = 9999

    static let modeLimit = 8

    static let tabWidth = 8

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




    // MARK: - Drawing

    var blankRow: [Cell] { Array(repeating: Cell(), count: columns) }

}
