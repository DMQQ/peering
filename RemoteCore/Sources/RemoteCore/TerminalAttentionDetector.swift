import Foundation

/// Recognises terminal output that has stopped for a person's answer.
///
/// A prompt may be split across reads and full-screen tools redraw it, so the detector keeps a short
/// tail and emits one attention event until ``userDidRespond()`` says the person has answered.
public struct TerminalAttentionDetector: Sendable {
    private static let maximumTailBytes = 4_096

    private var tail = Data()
    private var isAwaitingResponse = false

    public init() {}

    public mutating func receive(_ data: Data) -> TerminalAttentionKind? {
        guard !data.isEmpty else { return nil }

        tail.append(data)
        if tail.count > Self.maximumTailBytes {
            tail.removeFirst(tail.count - Self.maximumTailBytes)
        }

        guard !isAwaitingResponse, let kind = Self.detect(in: String(decoding: tail, as: UTF8.self)) else {
            return nil
        }
        isAwaitingResponse = true
        return kind
    }

    public mutating func userDidRespond() {
        tail.removeAll(keepingCapacity: true)
        isAwaitingResponse = false
    }

    /// The last visible line, which is the question being asked. It names who is asking ("[sudo] password for damian:" vs ssh), without which two shells produced identical notifications. Empty when the tail is not readable (a full-screen program repaints with cursor moves).
    public var question: String? {
        Self.question(inPlainText: plainText)
    }

    private var plainText: String {
        Self.plain(String(decoding: tail, as: UTF8.self))
    }

    /// The same rule for a terminal read from outside (Accessibility text, already plain), so both places make one judgement.
    public static func question(inPlainText text: String) -> String? {
        chooserQuestion(of: text) ?? lastLine(of: text)
    }

    /// The question above a Claude Code chooser. Its last line is the footer ("Esc to cancel",
    /// "tab to amend"), which says nothing about what is being asked.
    private static func chooserQuestion(of text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0) }
        guard let selected = lines.lastIndex(where: {
            $0.range(of: #"^\s*❯\s*\d+\.\s*.+"#, options: .regularExpression) != nil
        }) else { return nil }
        for line in lines[..<selected].reversed() {
            let cleaned = line.trimmingCharacters(in: .whitespaces)
            if cleaned.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil { continue }
            guard cleaned.contains("?") else { continue }
            return cleaned.count <= 160 ? cleaned : nil
        }
        return nil
    }

    private static func lastLine(of text: String) -> String? {
        // `whereSeparator: \.isNewline`, not "\n": CRLF is one grapheme that a "\n" search misses, so the tail came back as one line and every prompt was refused as too long.
        guard let line = text
            .split(whereSeparator: \.isNewline)
            .last
            .map({ $0.trimmingCharacters(in: .whitespaces) }),
              !line.isEmpty,
              line.count <= 80,
              !line.unicodeScalars.contains(where: {
                  $0.properties.isDefaultIgnorableCodePoint || $0.value < 0x20
              })
        else { return nil }
        return line
    }

    /// For text already rendered, with no ANSI codes (as the Accessibility API returns).
    public static func scan(_ text: String) -> TerminalAttentionKind? {
        detect(in: text)
    }

    /// Strips CSI sequences (cursor, colour, clear) and OSC sequences (window title) so only drawn text remains.
    private static func plain(_ rawText: String) -> String {
        rawText
            .replacingOccurrences(
                of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)",
                with: "",
                options: .regularExpression
            )
    }

    private static func detect(in rawText: String) -> TerminalAttentionKind? {
        let candidate = String(plain(rawText).lowercased().suffix(1_200))

        if candidate.range(
            of: #"(?:password|passphrase)(?: for [^:\n]+)?:\s*$"#,
            options: .regularExpression
        ) != nil {
            return .password
        }

        let conventionalPatterns = [
            #"(?:\[|\()(?:y/n|yes/no)(?:\]|\))\??\s*$"#,
            #"are you sure[^\n]*\??\s*$"#,
            #"press (?:enter|return)[^\n]*$"#,
            #"continue\?\s*$"#,
        ]
        if conventionalPatterns.contains(where: {
            candidate.range(of: $0, options: .regularExpression) != nil
        }) {
            return .confirmation
        }

        // Claude Code paints a multi-line chooser rather than ending in `[y/n]`: a question plus a
        // `❯`-marked row and another numbered row is an interaction, not ordinary command output.
        let lines = candidate.split(whereSeparator: \.isNewline)
        let hasQuestion = lines.contains { $0.contains("?") }
        let hasSelectedChoice = lines.contains {
            $0.range(
                of: #"^\s*❯\s*\d+\.\s*.+"#,
                options: .regularExpression
            ) != nil
        }
        let choiceCount = lines.count {
            $0.range(
                of: #"^\s*(?:❯\s*)?\d+\.\s*.+"#,
                options: .regularExpression
            ) != nil
        }

        return hasQuestion && hasSelectedChoice && choiceCount >= 2 ? .confirmation : nil
    }
}
