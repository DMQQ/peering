import Foundation

/// A unified diff as the chat draws it: the file header pair the CLI writes (old and new path) is not two diff lines.
public struct AgentDiffLines: Equatable {
    public enum Kind: Equatable {
        case added, removed, context
    }

    public struct Line: Equatable {
        public let kind: Kind
        public let text: String
    }

    public let path: String?
    public let lines: [Line]
    public let added: Int
    public let removed: Int

    public init(_ diff: String) {
        let raw = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        path = raw.first { $0.hasPrefix("+++ ") }.map { String($0.dropFirst(4)) }
        lines = raw
            .filter { !$0.hasPrefix("--- ") && !$0.hasPrefix("+++ ") }
            .map { line in
                if line.hasPrefix("+") { return Line(kind: .added, text: String(line.dropFirst())) }
                if line.hasPrefix("-") { return Line(kind: .removed, text: String(line.dropFirst())) }
                return Line(kind: .context, text: line)
            }
        added = lines.filter { $0.kind == .added }.count
        removed = lines.filter { $0.kind == .removed }.count
    }
}
