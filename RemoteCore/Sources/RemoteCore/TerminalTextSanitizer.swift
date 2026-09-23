import Foundation

/// A conservative plain-text renderer for PTY history: it removes CSI and OSC commands and handles
/// the cursor controls most progress output uses, rather than pretending to be a full terminal.
public enum TerminalTextSanitizer {
    /// A rendered line, and what it looks like it is.
    public struct Line: Equatable, Sendable {
        public let text: String
        public let kind: Kind

        public init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    public enum Kind: Equatable, Sendable {
        case plain
        /// Something did not work.
        case error
        /// Something is worth reading but is not a failure.
        case warning
    }

    /// The same rendering, split into lines and classified.
    ///
    /// Classification is a guess from the text: the colours are stripped, and the messages that
    /// matter most, such as a command that does not exist, are printed in plain text anyway.
    public static func renderLines(_ data: Data) -> [Line] {
        render(data)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Line(text: String($0), kind: kind(of: String($0))) }
    }

    /// Strong signals, and nothing else.
    ///
    /// A rule loose enough to catch every failure colours half the screen, so these are the phrases
    /// a shell and the common tools use, matched anywhere in the line and case-insensitively.
    static let errorSignals = [
        "command not found",
        "no such file or directory",
        "permission denied",
        "operation not permitted",
        "cannot find",
        "unrecognized",
        "not a valid",
        "fatal:",
        "error:",
        "failed",
        "aborted",
    ]

    static let warningSignals = [
        "warning:",
        "warn:",
        "deprecated",
    ]

    static func kind(of line: String) -> Kind {
        let lowered = line.lowercased()
        if errorSignals.contains(where: lowered.contains) { return .error }
        if warningSignals.contains(where: lowered.contains) { return .warning }
        return .plain
    }

    /// Whether a run of output says the command that produced it did not exist.
    ///
    /// Decides whether a command is worth keeping in the history: "command not found" is the shell
    /// saying it never ran, and a command that runs and fails is still a command.
    public static func reportsUnknownCommand(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self).lowercased().contains("command not found")
    }

    public static func render(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)

        // The escape and bell characters are written as themselves, not as `\u{001B}` inside the
        // pattern: a backslash-u-brace is not an escape to the regex engine here but six literal
        // characters, so a pattern written that way matches nothing.
        let escape = "\u{001B}"
        let bell = "\u{0007}"

        // Operating system commands: ESC ] … BEL (or ESC \).
        text = text.replacingOccurrences(
            of: "\(escape)\\][^\(bell)\(escape)]*(?:\(bell)|\(escape)\\\\)",
            with: "",
            options: .regularExpression
        )
        // Control sequences: colours, cursor moves, erase. ESC [ with parameters and a final byte.
        text = text.replacingOccurrences(
            of: "\(escape)\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )

        // Scalars, not characters: Swift treats a carriage return followed by a line feed as a
        // single `Character`, so a loop over `Character` never matches `case "\r"` or `case "\n"`
        // for the line endings a PTY sends, and the pair is dropped as control characters. The
        // whole history then comes out as one unbroken line.
        var rendered: [Unicode.Scalar] = []
        var lineStart = 0
        var cursor = 0
        var overwroteLine = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r":
                cursor = lineStart
                overwroteLine = true
            case "\u{08}":
                if cursor > lineStart { cursor -= 1 }
            case "\n":
                // The tail is cut only when the return actually went somewhere: a progress bar
                // writes over the line and then ends it, while a plain CRLF writes nothing after
                // the return and cutting there would delete the line that was just printed.
                if overwroteLine, cursor > lineStart {
                    rendered.removeSubrange(cursor..<rendered.count)
                }
                rendered.append("\n")
                cursor = rendered.count
                lineStart = cursor
                overwroteLine = false
            default:
                let allowed = scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
                guard allowed else { continue }
                if cursor < rendered.count, rendered[cursor] != "\n" {
                    rendered[cursor] = scalar
                } else {
                    rendered.append(scalar)
                }
                cursor += 1
            }
        }
        return String(String.UnicodeScalarView(rendered))
    }
}
