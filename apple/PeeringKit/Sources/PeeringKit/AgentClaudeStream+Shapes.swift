import Foundation
import RemoteCore

extension AgentClaudeStream {
    // MARK: - Shapes

    /// One tool call as the card will draw it.
    static func call(
        id: String,
        name: String,
        input: [String: Any],
        displayName: String? = nil
    ) -> AgentToolCall {
        if name == "AskUserQuestion", let asked = input["questions"] as? [[String: Any]] {
            let questions = asked.compactMap { entry -> AgentQuestion? in
                guard let question = entry["question"] as? String else { return nil }
                let options = (entry["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentToolOption? in
                    guard let label = option["label"] as? String else { return nil }
                    return AgentToolOption(label: label, detail: option["description"] as? String)
                }
                return AgentQuestion(header: entry["header"] as? String, question: question, options: options)
            }
            return AgentToolCall(
                id: id,
                name: name,
                title: questions.first?.header ?? "Question",
                detail: questions.first?.question,
                questions: questions.isEmpty ? nil : questions
            )
        }

        if name == "ExitPlanMode" {
            return AgentToolCall(id: id, name: name, title: "Plan", detail: input["plan"] as? String)
        }

        if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
            let steps = todos.compactMap { todo -> AgentPlanStep? in
                guard let text = todo["content"] as? String else { return nil }
                return AgentPlanStep(text: text, status: AgentPlanStep.status(from: todo["status"] as? String))
            }
            return AgentToolCall(id: id, name: name, title: "Plan", plan: steps.isEmpty ? nil : steps)
        }

        let filePath = input["file_path"] as? String
        let detail: String?
        switch name {
        case "Bash": detail = input["command"] as? String
        case "Read", "Write", "Edit", "NotebookEdit": detail = filePath
        case "Glob", "Grep": detail = input["pattern"] as? String
        case "WebFetch": detail = input["url"] as? String
        case "WebSearch": detail = input["query"] as? String
        case "Task": detail = input["description"] as? String
        default: detail = nil
        }
        let diff: String?
        if name == "Edit",
           let old = input["old_string"] as? String, let new = input["new_string"] as? String {
            diff = AgentDiff.replacement(old: old, new: new, path: filePath)
        } else {
            diff = nil
        }
        let title: String
        if let displayName, !displayName.isEmpty {
            title = displayName
        } else {
            title = name
        }
        return AgentToolCall(
            id: id,
            name: name,
            title: title,
            detail: detail,
            filePath: filePath,
            diff: diff
        )
    }

    /// A tool result's content, which is a string or a list of blocks, one of which may be a
    /// picture this wire does not carry.
    static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { parts.append(text) }
            case "image":
                parts.append("[a picture, not shown here]")
            default:
                continue
            }
        }
        return parts.joined(separator: "\n")
    }
}
