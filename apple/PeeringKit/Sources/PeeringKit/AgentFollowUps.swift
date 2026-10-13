import Foundation
import RemoteCore

/// What is worth offering after an agent finishes a turn, read from what the turn did.
public enum AgentFollowUps {
    public enum Suggestion: Equatable, Sendable {
        case reviewChanges
        case runTests
        case summarizeChanges
    }

    private static let editingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch", "file_change"]

    /// Nothing while the agent is busy, waiting, or has not done anything to the project: a chat that only answered a question has no next step to guess at.
    public static func suggestions(for transcript: AgentTranscript) -> [Suggestion] {
        guard transcript.state == .idle, case .summary? = transcript.items.last else { return [] }
        let turn = transcript.items.reversed().prefix { if case .user = $0 { return false } else { return true } }
        let tools = turn.compactMap { item -> AgentToolItem? in
            if case .tool(_, let tool) = item { return tool }
            return nil
        }
        let edited = tools.contains { tool in
            tool.state == .ok && (editingTools.contains(tool.call.name) || tool.call.diff?.isEmpty == false)
        }
        guard edited else { return [] }
        let ranTests = tools.contains { tool in
            tool.call.detail?.localizedCaseInsensitiveContains("test") == true
        }
        return [.reviewChanges] + (ranTests ? [] : [.runTests]) + [.summarizeChanges]
    }
}
