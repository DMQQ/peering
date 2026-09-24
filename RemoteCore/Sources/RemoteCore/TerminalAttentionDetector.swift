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

    /// The last visible line of what the shell has drawn, which is the question it is asking.
    ///
    /// **Because the prompt names whoever is asking.** "[sudo] password for damian:" and
    /// "damian@example.com's password:" both say who wants the password and which password it is,
    /// and a sentence that only reported "waiting for a password" said neither: two shells on one
    /// Mac, one asking for sudo and one asking for ssh, produced two identical notifications.
    ///
    /// Read from the same tail the detection reads, so it is written in the terms of the prompt
    /// that was just recognised. Empty when that tail does not end in something readable: a
    /// full-screen program repaints with cursor moves rather than lines.
    public var question: String? {
        Self.lastLine(of: plainText)
    }

    /// The tail with its terminal control sequences taken out, which is the text a person sees.
    private var plainText: String {
        Self.plain(String(decoding: tail, as: UTF8.self))
    }

    /// The same rule, for a terminal read from outside.
    ///
    /// A terminal emulator watched through the Accessibility API has no tail of its own: it hands
    /// over the text it can see, already plain, and asks the detector what the last line of it is.
    /// One rule rather than two, because "this line is a prompt" is the same judgement in both
    /// places, down to the bound that refuses a screenful of repainted nothing.
    public static func question(inPlainText text: String) -> String? {
        lastLine(of: text)
    }

    private static func lastLine(of text: String) -> String? {
        // `whereSeparator: \.isNewline` rather than a separator of "\n", and the difference is a
        // real one: a shell that ends its lines the DOS way writes CRLF as a single *grapheme*,
        // which a search for the "\n" character does not match, so the whole tail came back as one
        // line and every prompt was refused for being too long.
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

    /// Scans plain visible text for patterns that require the user's response.
    ///
    /// For text already rendered, with no ANSI codes, as the Accessibility API returns it for a
    /// native terminal emulator's text area.
    public static func scan(_ text: String) -> TerminalAttentionKind? {
        detect(in: text)
    }

    /// The text as a person sees it: everything the terminal uses to *place* characters removed,
    /// everything it draws left in place.
    ///
    /// Two passes, because terminals use two: the CSI sequences (`ESC [ ... `) that move the
    /// cursor, set colour and clear lines, and the OSC ones (`ESC ] ... BEL`) that set a window
    /// title. Neither carries anything a notification wants to quote.
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
