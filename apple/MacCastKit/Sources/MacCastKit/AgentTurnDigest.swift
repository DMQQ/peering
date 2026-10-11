import Foundation
import RemoteCore

/// What a finished turn did, in the few words a notification has room for.
public enum AgentTurnDigest {
    private static let editingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// Whether a call changes a file: a named editing tool, or any CLI's call that carries a diff.
    public static func edits(_ call: AgentToolCall) -> Bool {
        call.filePath != nil && (editingTools.contains(call.name) || call.diff != nil)
    }

    /// "3 files changed · 2m 14s", or nil when the turn changed nothing and took no time worth saying.
    public static func detail(editedFiles: Int, duration: TimeInterval?) -> String? {
        var parts: [String] = []
        if editedFiles > 0 { parts.append(editedFiles == 1 ? "1 file changed" : "\(editedFiles) files changed") }
        if let duration, duration >= 5 { parts.append(AgentTurnFormat.duration(duration)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
