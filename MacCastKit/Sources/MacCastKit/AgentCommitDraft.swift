import Foundation
import RemoteCore

/// A one-line commit message worked out from which files changed and how, with nothing guessed about why.
public enum AgentCommitDraft {
    public static func message(for files: [AgentChangedFile]) -> String {
        let names = displayNames(for: files)
        let segments: [(verb: String, names: [String])] = [
            ("Add", files.filter { $0.kind == .added || $0.kind == .untracked }.map { names[$0.path] ?? $0.path }),
            ("Update", files.filter { $0.kind == .modified }.map { names[$0.path] ?? $0.path }),
            ("Remove", files.filter { $0.kind == .deleted }.map { names[$0.path] ?? $0.path }),
        ].filter { !$0.names.isEmpty }
        guard !segments.isEmpty else { return "" }
        let clauses = segments.enumerated().map { index, segment in
            let verb = index == 0 ? segment.verb : segment.verb.lowercased()
            return verb + " " + object(of: segment.names)
        }
        return join(clauses)
    }

    /// The file's name, or its path where two chosen files share a name.
    private static func displayNames(for files: [AgentChangedFile]) -> [String: String] {
        let last = { (path: String) in (path as NSString).lastPathComponent }
        let counts = Dictionary(grouping: files, by: { last($0.path) }).mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: files.map { ($0.path, (counts[last($0.path)] ?? 0) > 1 ? $0.path : last($0.path)) })
    }

    private static func object(of names: [String]) -> String {
        switch names.count {
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        case 3: "\(names[0]), \(names[1]) and \(names[2])"
        default: "\(names.count) files"
        }
    }

    private static func join(_ clauses: [String]) -> String {
        guard clauses.count > 1 else { return clauses.first ?? "" }
        return clauses.dropLast().joined(separator: ", ") + " and " + clauses[clauses.count - 1]
    }
}
