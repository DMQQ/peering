import Foundation

/// A conservative plain-text renderer for PTY history. It intentionally does not pretend to be
/// a full terminal emulator, but removes CSI/OSC commands and handles the cursor controls most
/// command-line progress output uses so SwiftUI never displays raw escape garbage.
public enum TerminalTextSanitizer {
    public static func render(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(
            of: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )

        var rendered: [Character] = []
        var lineStart = 0
        var cursor = 0
        var overwroteLine = false
        for character in text {
            switch character {
            case "\r":
                cursor = lineStart
                overwroteLine = true
            case "\u{08}":
                if cursor > lineStart { cursor -= 1 }
            case "\n":
                if overwroteLine, cursor < rendered.count {
                    rendered.removeSubrange(cursor..<rendered.count)
                }
                rendered.append("\n")
                cursor = rendered.count
                lineStart = cursor
                overwroteLine = false
            default:
                let allowed = character == "\t" || !character.unicodeScalars.contains {
                    CharacterSet.controlCharacters.contains($0)
                }
                guard allowed else { continue }
                if cursor < rendered.count, rendered[cursor] != "\n" {
                    rendered[cursor] = character
                } else {
                    rendered.append(character)
                }
                cursor += 1
            }
        }
        return String(rendered)
    }
}
