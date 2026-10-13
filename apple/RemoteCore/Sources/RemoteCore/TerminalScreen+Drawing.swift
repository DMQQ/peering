import Foundation

extension TerminalScreen {
    mutating func put(_ character: Character) {
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

    mutating func advance() {
        guard row == rows - 1 else {
            row += 1
            return
        }
        let top = grid.removeFirst()
        record(top)
        grid.append(blankRow)
    }

    /// Takes a scrolled-off row whole, so its colour goes into the history, keeping it bounded. Dropped while the alternate screen is up.
    mutating func record(_ scrolled: [Cell]) {
        guard !alternate else { return }
        history.append(scrolled)
        styledHistory.append(styledLine(scrolled))
        guard history.count > Self.scrollbackLimit + Self.scrollbackSlack else { return }
        let excess = history.count - Self.scrollbackLimit
        history.removeFirst(excess)
        styledHistory.removeFirst(excess)
    }

    mutating func control(_ byte: UInt8) {
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
    func drawnLength(of row: [Cell]) -> Int {
        var end = row.count
        while end > 0, row[end - 1].isBlank { end -= 1 }
        return end
    }

    func text(of row: [Cell]) -> String {
        String(row[0..<drawnLength(of: row)].map(\.character))
    }

    /// Consecutive cells of one rendition become one run, so cost follows colour changes rather than width.
    func styledLine(_ row: [Cell]) -> TerminalStyledLine {
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
    func isEightBitControl(_ scalar: Unicode.Scalar) -> Bool {
        (0x80...0x9F).contains(scalar.value)
    }
}
