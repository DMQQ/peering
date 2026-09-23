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

    /// Consumes one piece of PTY output and returns the newly recognised kind of prompt, if any.
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

    /// Starts a fresh prompt cycle after input has been sent to the terminal.
    public mutating func userDidRespond() {
        tail.removeAll(keepingCapacity: true)
        isAwaitingResponse = false
    }

    /// Scans plain visible text for patterns that require the user's response.
    ///
    /// For text already rendered, with no ANSI codes, as the Accessibility API returns it for a
    /// native terminal emulator's text area.
    public static func scan(_ text: String) -> TerminalAttentionKind? {
        detect(in: text)
    }

    private static func detect(in rawText: String) -> TerminalAttentionKind? {
        let withoutCSI = rawText.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        let plain = withoutCSI.replacingOccurrences(
            of: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)",
            with: "",
            options: .regularExpression
        ).lowercased()
        let candidate = String(plain.suffix(1_200))

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
