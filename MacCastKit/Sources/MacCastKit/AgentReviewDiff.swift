import Foundation

/// A unified diff split into numbered lines, so a comment can name `file:line`.
public struct AgentReviewDiff: Equatable {
    public enum Kind: Equatable {
        case hunk, added, removed, context
    }

    public struct Line: Equatable, Identifiable {
        public let id: Int
        public let kind: Kind
        public let oldNumber: Int?
        public let newNumber: Int?
        public let text: String

        /// What a comment on this line points at: the new file's line, or the old one's for a removed line.
        public var isCommentable: Bool { kind != .hunk }
    }

    public let lines: [Line]

    /// Everything before the first `@@` (the `diff --git`, `index` and `---`/`+++` lines) is dropped.
    public init(_ diff: String) {
        var result: [Line] = []
        var old = 0
        var new = 0
        var inHunk = false
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(raw)
            if text.hasPrefix("@@") {
                (old, new) = Self.starts(of: text)
                inHunk = true
                result.append(Line(id: result.count, kind: .hunk, oldNumber: nil, newNumber: nil, text: text))
            } else if inHunk {
                if text.hasPrefix("+") {
                    result.append(Line(id: result.count, kind: .added, oldNumber: nil, newNumber: new, text: String(text.dropFirst())))
                    new += 1
                } else if text.hasPrefix("-") {
                    result.append(Line(id: result.count, kind: .removed, oldNumber: old, newNumber: nil, text: String(text.dropFirst())))
                    old += 1
                } else if text.hasPrefix("\\") {
                    continue
                } else {
                    result.append(Line(id: result.count, kind: .context, oldNumber: old, newNumber: new, text: String(text.dropFirst(text.isEmpty ? 0 : 1))))
                    old += 1
                    new += 1
                }
            }
        }
        lines = result
    }

    /// `@@ -12,5 +14,7 @@ context` gives 12 and 14; a header that does not parse starts both at 1.
    private static func starts(of header: String) -> (Int, Int) {
        let numbers = header.split(separator: " ").dropFirst().prefix(2).map { part -> Int? in
            Int(part.dropFirst().split(separator: ",").first ?? "")
        }
        guard numbers.count == 2, let old = numbers[0], let new = numbers[1] else { return (1, 1) }
        return (old, new)
    }
}
