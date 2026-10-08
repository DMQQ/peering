import Foundation
import RemoteCore

/// What a running agent is doing right now and where it is in its own plan, read off the transcript so a list can say it without opening the chat.
public struct AgentPlanProgress: Equatable {
    public let steps: [AgentPlanStep]

    public var completed: Int { steps.filter { $0.status == .completed }.count }
    public var total: Int { steps.count }
    public var isFinished: Bool { completed == total }

    /// The step being worked on, else the first not yet done.
    public var current: AgentPlanStep? {
        steps.first { $0.status == .inProgress } ?? steps.first { $0.status == .pending }
    }

    /// One-based, for "step 3 of 7".
    public var currentNumber: Int? {
        guard let current, let index = steps.firstIndex(of: current) else { return nil }
        return index + 1
    }
}

extension AgentTranscript {
    /// The newest plan any to-do tool wrote: each call restates the whole list.
    public var planProgress: AgentPlanProgress? {
        latestPlan.map { AgentPlanProgress(steps: $0) }
    }

    /// A short present-tense line while a turn runs, nil otherwise.
    public var activity: String? {
        switch state {
        case .working:
            break
        case .awaitingApproval:
            if let call = pendingApprovals.first?.call {
                return "Waiting to " + Self.describe(call).lowercasedFirst
            }
            return nil
        default:
            return nil
        }
        for item in items.suffix(40).reversed() {
            switch item {
            case .tool(_, let tool) where tool.state == .running:
                return Self.describe(tool.call)
            case .reply:
                return "Writing a reply"
            case .user:
                return "Thinking"
            case .tool, .notice, .failure, .summary:
                continue
            }
        }
        return "Thinking"
    }

    static func describe(_ call: AgentToolCall) -> String {
        let detail = call.detail?
            .split(whereSeparator: \.isNewline).first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        let file = (call.filePath ?? detail).map { ($0 as NSString).lastPathComponent }
        func with(_ verb: String, _ object: String?) -> String {
            guard let object, !object.isEmpty else { return verb }
            let shortened = object.count > 56 ? String(object.prefix(55)) + "…" : object
            return verb + " " + shortened
        }
        switch call.name.lowercased() {
        case "bash", "command", "command_execution", "shell":
            return with("Running", detail ?? "a command")
        case "read":
            return with("Reading", file)
        case "write", "edit", "multiedit", "notebookedit", "patch", "apply_patch", "file_change":
            return with("Editing", file)
        case "grep", "glob", "list", "web_search", "websearch":
            return with("Searching", detail)
        case "webfetch":
            return with("Fetching", detail)
        case "task", "agent":
            return with("Delegating", detail)
        case "todowrite", "todoread", "todo_list":
            return "Updating the plan"
        default:
            return with(call.title, detail)
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
