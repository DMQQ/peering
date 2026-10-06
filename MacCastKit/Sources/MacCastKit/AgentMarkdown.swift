import Foundation

/// An assistant's text, split into the blocks a chat draws differently.
///
/// Not a markdown parser: the paragraphs keep their inline markdown for the text view to render,
/// and what this decides is only where one kind of block ends and the next begins. Fenced code
/// and bullet lists are the two that cannot be drawn as a sentence; everything else is prose.
public enum AgentMarkdown {
    public enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        /// A fenced block's contents, fence markers removed. The language, when named, is dropped:
        /// nothing here colours syntax.
        case code(String)
        case bullets([String])
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

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
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

        // An unclosed fence is the stream caught mid-block, not a fault: what arrived is code
        // until the closing line does or the turn ends.
        if inCode {
            blocks.append(.code(code.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    /// `#` through `######`, with the space an ATX heading requires. Without the space the line
    /// is a paragraph starting with hashes, which is what a shell transcript looks like.
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
