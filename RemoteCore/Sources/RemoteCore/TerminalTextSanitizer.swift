import Foundation

/// A conservative plain-text renderer for PTY history. It intentionally does not pretend to be
/// a full terminal emulator, but removes CSI/OSC commands and handles the cursor controls most
/// command-line progress output uses so SwiftUI never displays raw escape garbage.
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
    /// Classification is a guess from the text, and it is worth being honest about why it is not
    /// something better. The colours a shell emits are its own and they are stripped here — and
    /// they would not have helped anyway: the messages that matter most, like a command that does
    /// not exist, are printed by the shell in plain text with no colour on them at all.
    public static func renderLines(_ data: Data) -> [Line] {
        render(data)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Line(text: String($0), kind: kind(of: String($0))) }
    }

    /// Strong signals, and nothing else.
    ///
    /// The point of a colour here is that a failure is findable by skimming, and a rule loose
    /// enough to catch *every* failure is a rule that colours half the screen — a file called
    /// `error.log` in a listing, the word "error" quoted inside a log line, a script printing its
    /// own status. These are the phrases a shell and the common tools use to say that something
    /// failed, matched anywhere in the line and case-insensitively.
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
    /// A narrow question with a narrow answer, because it decides whether a command is worth
    /// keeping in the history: "command not found" is the shell saying it never ran. Nothing else
    /// counts — a command that runs and fails is a command, and saving only the ones that
    /// succeeded would be a history of the easy parts.
    public static func reportsUnknownCommand(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self).lowercased().contains("command not found")
    }

    public static func render(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)

        // The escape and bell characters are written as themselves, not as `\u{001B}` inside the
        // pattern. A backslash-u-brace is not an escape character to the regex engine here — it is
        // six literal characters — so the pattern compiled, matched nothing, and every ANSI colour
        // code a shell emits arrived on screen as its own source text: `[32mgreen[0m`.
        let escape = "\u{001B}"
        let bell = "\u{0007}"

        // Operating system commands: ESC ] … BEL (or ESC \).
        text = text.replacingOccurrences(
            of: "\(escape)\\][^\(bell)\(escape)]*(?:\(bell)|\(escape)\\\\)",
            with: "",
            options: .regularExpression
        )
        // Control sequences: colours, cursor moves, erase — ESC [ with parameters and a final byte.
        text = text.replacingOccurrences(
            of: "\(escape)\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )

        // **Scalars, not characters.**
        //
        // Swift treats a carriage return followed by a line feed as a *single* `Character` — a
        // CRLF grapheme cluster — so a loop over `Character` never matches `case "\r"` or
        // `case "\n"` for the line endings a PTY actually sends. Both fall to the default branch,
        // which drops the pair as control characters, and the whole history comes out as one
        // unbroken line: "hello\r\nworld\r\n" rendered as "helloworld". A terminal that runs
        // every command into the next one looks like a rendering fault and is one.
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
                // The rest of the line is dropped only when the return actually went somewhere:
                // a progress bar writes over the line and then ends it, so there is a tail left
                // to cut. A plain CRLF writes nothing after the return, so `cursor` is still at
                // `lineStart` — and cutting there would delete the line that was just printed,
                // which is what turned every line of output into a blank one.
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
