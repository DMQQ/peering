import Foundation
import RemoteCore

/// One file the agent edited in the conversation, as the transcript recorded it.
public struct AgentFileEdit: Equatable {
    public let path: String
    /// The edit's own diff, where the CLI sent one; a whole-file write carries none.
    public let diff: String?

    public init(path: String, diff: String? = nil) {
        self.path = path
        self.diff = diff
    }
}

/// A file that changed, from whichever source knew about it.
public struct AgentChangeEntry: Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    /// Nil when only the transcript knows of it, so git has not confirmed a difference.
    public let kind: AgentChangeKind?
    public let added: Int
    public let removed: Int
    /// Git's diff against the last commit when there is one, else the agent's own.
    public let diff: String?
    public let editedByAgent: Bool
    /// Whether ``diff`` is git's, and so has hunk headers and line numbers.
    public let isGitDiff: Bool
}

extension AgentChangeEntry {
    /// One letter for the row: what git calls the file, or a dot where only the transcript has seen it.
    public var marker: String {
        switch kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .untracked: "U"
        case nil: "\u{00B7}"
        }
    }
}

public enum AgentChangeSet {
    public static let editToolNames: Set<String> = [
        "Edit", "Write", "NotebookEdit", "MultiEdit", "edit", "write", "patch", "multiedit", "file_change",
    ]

    /// Files the agent (and its sub-agents) edited and the CLI did not refuse.
    public static func edits(in transcript: AgentTranscript, directory: String) -> [AgentFileEdit] {
        var found: [AgentFileEdit] = []
        func collect(_ transcript: AgentTranscript) {
            for case .tool(_, let tool) in transcript.items {
                guard editToolNames.contains(tool.call.name) || tool.call.title == "Edit" || tool.call.title == "Write",
                      tool.state != .failed, tool.state != .denied,
                      let absolute = tool.call.filePath,
                      let path = relativePath(absolute, in: directory)
                else { continue }
                found.append(AgentFileEdit(path: path, diff: tool.call.diff))
            }
            for child in transcript.children.values { collect(child) }
        }
        collect(transcript)
        return found
    }

    /// A path inside the folder, relative to it; nil for one outside.
    public static func relativePath(_ path: String, in directory: String) -> String? {
        let root = directory.hasSuffix("/") ? directory : directory + "/"
        let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
        return AgentChangePath.isInsideFolder(relative) ? relative : nil
    }

    public static func entries(report: AgentChangesReport?, edits: [AgentFileEdit]) -> [AgentChangeEntry] {
        var byPath: [String: AgentChangeEntry] = [:]
        let edited = Set(edits.map(\.path))
        for file in report?.files ?? [] {
            byPath[file.path] = AgentChangeEntry(
                path: file.path, kind: file.kind, added: file.added, removed: file.removed,
                diff: file.diff, editedByAgent: edited.contains(file.path), isGitDiff: true
            )
        }
        for path in edited where byPath[path] == nil {
            let diffs = edits.filter { $0.path == path }.compactMap(\.diff)
            let reading = diffs.map(AgentDiffLines.init)
            byPath[path] = AgentChangeEntry(
                path: path, kind: nil,
                added: reading.reduce(0) { $0 + $1.added }, removed: reading.reduce(0) { $0 + $1.removed },
                diff: diffs.isEmpty ? nil : diffs.joined(separator: "\n"), editedByAgent: true, isGitDiff: false
            )
        }
        return byPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
