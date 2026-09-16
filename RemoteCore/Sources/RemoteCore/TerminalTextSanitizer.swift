import Foundation

/// A conservative plain-text renderer for PTY history. It intentionally does not pretend to be
/// a full terminal emulator, but removes CSI/OSC commands and handles the cursor controls most
/// command-line progress output uses so SwiftUI never displays raw escape garbage.
public enum TerminalTextSanitizer {
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
