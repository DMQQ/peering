package pl.dmq.peering.session.terminal.screen

/**
 * A minimal terminal screen: a grid of characters and a cursor that escape sequences move, enough for programs that
 * draw by positioning. It is not a full terminal: no scrolling region, no origin mode, one code point per cell and no
 * DEC line drawing. Not thread safe; the caller serialises access.
 */
class VtScreen(columns: Int = 80, rows: Int = 24) : TerminalEmulator {
    override var columns: Int = maxOf(1, columns)
        private set
    override var rows: Int = maxOf(1, rows)
        private set

    private var grid: Array<Array<ScreenCell>> = Array(this.rows) { blankRow() }
    private val history = ArrayDeque<List<ScreenCell>>()
    private val styledHistory = ArrayDeque<StyledLine>()
    private val parser = VtParser(this)

    internal var row = 0
        private set
    internal var column = 0
        private set
    internal var attributes = CellAttributes()

    /** A terminal wraps when asked to write past the last column, not on writing it, or full-width padding would scroll. */
    private var pendingWrap = false
    private var alternate = false

    override fun feed(bytes: ByteArray) {
        for (byte in bytes) parser.consume(byte.toInt() and 0xFF)
    }

    /** Keeps the cells and lets the program paint over them; scrollback is not re-wrapped. */
    override fun resize(columns: Int, rows: Int) {
        val newColumns = maxOf(1, columns)
        val newRows = maxOf(1, rows)
        if (newColumns == this.columns && newRows == this.rows) return
        val rowsList = grid.toMutableList()
        if (newRows < this.rows && row >= newRows) {
            repeat(row - newRows + 1) {
                record(rowsList.removeAt(0).toList())
                rowsList.add(Array(this.columns) { ScreenCell.BLANK })
            }
            row = newRows - 1
        }
        grid = Array(newRows) { index ->
            val cells = rowsList.getOrNull(index)
            Array(newColumns) { cell -> cells?.getOrNull(cell) ?: ScreenCell.BLANK }
        }
        this.columns = newColumns
        this.rows = newRows
        row = minOf(row, newRows - 1)
        column = minOf(column, newColumns - 1)
        pendingWrap = false
    }

    override fun snapshot(): ScreenSnapshot {
        val screenLines = grid.map(::styledLine).toMutableList()
        while (screenLines.size > row + 1 && screenLines.last().runs.isEmpty()) screenLines.removeAt(screenLines.lastIndex)
        return ScreenSnapshot(
            lines = styledHistory.toList() + screenLines,
            cursorLine = styledHistory.size + row,
            cursorColumn = if (pendingWrap) columns - 1 else column,
            columns = columns,
            rows = rows,
            alternateScreen = alternate,
        )
    }

    /** Clamped to the screen: `CSI 99999999 H` lands bottom-right. */
    internal fun place(newRow: Int, newColumn: Int) {
        row = newRow.coerceIn(0, rows - 1)
        column = newColumn.coerceIn(0, columns - 1)
        pendingWrap = false
    }

    internal fun put(codePoint: Int) {
        if (pendingWrap) {
            column = 0
            advance()
            pendingWrap = false
        }
        grid[row][column] = ScreenCell(codePoint, attributes)
        if (column == columns - 1) pendingWrap = true else column += 1
    }

    internal fun control(byte: Int) {
        when (byte) {
            CARRIAGE_RETURN -> place(row, 0)
            LINE_FEED -> {
                // Only moves down: shell output arrives as CRLF, and resetting the column would fold drawing left.
                pendingWrap = false
                advance()
            }
            BACKSPACE -> place(row, column - 1)
            TAB -> place(row, (column / TAB_WIDTH + 1) * TAB_WIDTH)
        }
    }

    internal fun eraseLine(mode: Int) {
        when (mode) {
            0 -> clear(column, columns - 1, row)
            1 -> clear(0, column, row)
            2 -> clear(0, columns - 1, row)
        }
    }

    internal fun eraseDisplay(mode: Int) {
        when (mode) {
            0 -> {
                clear(column, columns - 1, row)
                for (below in row + 1 until rows) clear(0, columns - 1, below)
            }
            1 -> {
                clear(0, column, row)
                for (above in 0 until row) clear(0, columns - 1, above)
            }
            2 -> clearScreen()
            3 -> {
                history.clear()
                styledHistory.clear()
                clearScreen()
            }
        }
    }

    /** A full-screen program's own blank page; rows scrolled off meanwhile are dropped, not added to scrollback. */
    internal fun alternateScreen(enabled: Boolean) {
        // Programs re-assert the mode on every refresh; clearing each time would erase the frame.
        if (enabled == alternate) return
        alternate = enabled
        attributes = CellAttributes()
        clearScreen()
    }

    private fun clearScreen() {
        grid = Array(rows) { blankRow() }
        place(0, 0)
    }

    /** Erases to the default rendition, not the current pen, or colour would be left in cells meant to be empty. */
    private fun clear(start: Int, end: Int, onRow: Int) {
        for (index in start..end) grid[onRow][index] = ScreenCell.BLANK
    }

    private fun advance() {
        if (row < rows - 1) {
            row += 1
            return
        }
        val top = grid[0]
        System.arraycopy(grid, 1, grid, 0, rows - 1)
        grid[rows - 1] = blankRow()
        record(top.toList())
    }

    private fun record(scrolled: List<ScreenCell>) {
        if (alternate) return
        history.addLast(scrolled)
        styledHistory.addLast(styledLine(scrolled))
        while (history.size > SCROLLBACK_LIMIT) {
            history.removeFirst()
            styledHistory.removeFirst()
        }
    }

    private fun blankRow(): Array<ScreenCell> = Array(columns) { ScreenCell.BLANK }

    private fun drawnLength(cells: Collection<ScreenCell>): Int {
        val list = cells as? List<ScreenCell> ?: cells.toList()
        var end = list.size
        while (end > 0 && list[end - 1].isBlank) end -= 1
        return end
    }

    private fun styledLine(cells: Array<ScreenCell>) = styledLine(cells.asList())

    /** Consecutive cells of one rendition become one run, so cost follows colour changes rather than width. */
    private fun styledLine(cells: List<ScreenCell>): StyledLine {
        val end = drawnLength(cells)
        val runs = mutableListOf<StyledRun>()
        var index = 0
        while (index < end) {
            val rendition = cells[index].attributes
            val text = StringBuilder()
            while (index < end && cells[index].attributes == rendition) {
                text.appendCodePoint(cells[index].codePoint)
                index += 1
            }
            runs.add(StyledRun(text.toString(), rendition.foreground, rendition.background, rendition.bold, rendition.dim))
        }
        return StyledLine(runs)
    }

    private companion object {
        const val SCROLLBACK_LIMIT = 2_000
        const val TAB_WIDTH = 8
        const val CARRIAGE_RETURN = 0x0D
        const val LINE_FEED = 0x0A
        const val BACKSPACE = 0x08
        const val TAB = 0x09
    }
}
