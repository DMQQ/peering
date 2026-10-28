import Foundation

/// An assistant's text, split into the blocks a chat draws differently.
public enum AgentMarkdown {
    public enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case code(String)
        case bullets([String])
        case table(Table)
    }

    public struct Table: Equatable {
        public enum Alignment: Equatable { case leading, center, trailing }

        public let header: [String]
        public let rows: [[String]]
        public let alignments: [Alignment]
    }

    public static func split(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var bullets: [String] = []
        var inCode = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        func flushBullets() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)) }
            bullets = []
        }
        func flushAll() {
            flushParagraph()
            flushBullets()
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if !inCode, let (table, consumed) = table(startingAt: index - 1, in: lines) {
                flushAll()
                blocks.append(.table(table))
                index = consumed
                continue
            }
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code = []
                    inCode = false
                } else {
                    flushAll()
                    inCode = true
                }
                continue
            }
            if inCode {
                code.append(line)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let heading = heading(in: trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                bullets.append(String(trimmed.dropFirst(2)))
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            flushBullets()
            paragraph.append(line)
        }

        if inCode {
            blocks.append(.code(code.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    /// A header row, a row of dashes under it, then every following line that still has a pipe in it. Without the dashes it is only a line with pipes in it, which is also what a table looks like while it is still arriving.
    private static func table(startingAt start: Int, in lines: [String]) -> (Table, Int)? {
        guard start + 1 < lines.count, lines[start].contains("|") else { return nil }
        let header = cells(of: lines[start])
        let rule = cells(of: lines[start + 1])
        guard header.count > 1 || lines[start].trimmingCharacters(in: .whitespaces).hasPrefix("|"),
              rule.count == header.count,
              rule.allSatisfy({ isRuleCell($0) })
        else { return nil }
        var rows: [[String]] = []
        var next = start + 2
        while next < lines.count, lines[next].contains("|"), !lines[next].hasPrefix("```") {
            var row = cells(of: lines[next])
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            rows.append(Array(row.prefix(header.count)))
            next += 1
        }
        return (Table(header: header, rows: rows, alignments: rule.map(alignment(of:))), next)
    }

    private static func cells(of line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        return trimmed.replacingOccurrences(of: "\\|", with: "\u{1}")
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    private static func isRuleCell(_ cell: String) -> Bool {
        let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
    }

    private static func alignment(of cell: String) -> Table.Alignment {
        switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
        case (true, true): .center
        case (false, true): .trailing
        default: .leading
        }
    }

    private static func heading(in trimmed: String) -> Block? {
        var level = 0
        var rest = Substring(trimmed)
        while rest.first == "#", level < 6 {
            level += 1
            rest = rest.dropFirst()
        }
        guard level > 0, rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: level, text: text)
    }
}
