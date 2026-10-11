import Foundation

public enum TerminalTextSanitizer {
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
        case error
        case warning
    }

    public static func renderLines(_ data: Data) -> [Line] {
        render(data)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Line(text: String($0), kind: kind(of: String($0))) }
    }

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

    public static func reportsUnknownCommand(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self).lowercased().contains("command not found")
    }

    public static func render(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)

        // Write the escape and bell as characters, not `\u{001B}` inside the pattern: the regex engine reads that as literals and matches nothing.
        let escape = "\u{001B}"
        let bell = "\u{0007}"

        text = text.replacingOccurrences(
            of: "\(escape)\\][^\(bell)\(escape)]*(?:\(bell)|\(escape)\\\\)",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\(escape)\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )

        // Scalars, not Characters: CRLF is one Character, so a loop over Character never matches "\r" or "\n" and the history comes out as one line.
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
                // Cut the tail only if the return actually went somewhere: a plain CRLF writes nothing after the return.
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
