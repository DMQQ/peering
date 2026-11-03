import Foundation
import RemoteCore

/// Gemini CLI's `--output-format stream-json` lines, turned into the app's own events.
public struct AgentGeminiStream {
    public static let agentID = "gemini"

    private let directory: String

    public init(directory: String, cliSessionID: String? = nil) {
        self.directory = directory
        self.cliSessionID = cliSessionID
    }

    public private(set) var cliSessionID: String?
    public private(set) var usage = AgentUsage()
    private var inTurn = false
    private var pendingText = ""
    private var model: String?
    private var announcedUnknownNames: Set<String> = []

    public mutating func receive(line: String) -> [AgentStreamEvent.Payload] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return [.notice(text: "A line of Gemini CLI's output could not be read.")]
        }

        switch type {
        case "init":
            return initialise(json)
        case "message":
            guard json["role"] as? String == "assistant", let text = json["content"] as? String else { return [] }
            pendingText += text
            return beginTurnIfNeeded()
        case "tool_use":
            return beginTurnIfNeeded() + flushText() + toolStarted(json)
        case "tool_result":
            return flushText() + toolFinished(json)
        case "error":
            let message = json["message"] as? String ?? "Gemini CLI reported an error."
            return [.notice(text: message)]
        case "result":
            return beginTurnIfNeeded() + flushText() + finish(json)
        default:
            return ignore(type)
        }
    }

    private mutating func initialise(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        model = json["model"] as? String
        guard let id = json["session_id"] as? String, id != cliSessionID else { return [] }
        cliSessionID = id
        return [.sessionReady(agentID: Self.agentID, cliSessionID: id, model: model, directory: directory)]
    }

    // MARK: - Turns

    private mutating func beginTurnIfNeeded() -> [AgentStreamEvent.Payload] {
        guard !inTurn else { return [] }
        inTurn = true
        return [.turnStarted]
    }

    private mutating func flushText() -> [AgentStreamEvent.Payload] {
        let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        guard !text.isEmpty else { return [] }
        let (kept, truncated) = AgentLimits.trimmed(text, to: AgentLimits.maximumToolOutputBytes)
        var events: [AgentStreamEvent.Payload] = [.textFinal(text: kept)]
        if truncated { events.append(.notice(text: "Part of a reply was too long to show.")) }
        return events
    }

    private mutating func finish(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        inTurn = false
        let stats = json["stats"] as? [String: Any] ?? [:]
        let input = stats["input_tokens"] as? Int
        let output = stats["output_tokens"] as? Int
        let cached = stats["cached"] as? Int ?? 0
        usage.inputTokens += max((input ?? 0) - cached, 0)
        usage.cachedTokens += cached
        usage.outputTokens += output ?? 0
        if let total = stats["total_tokens"] as? Int { usage.contextUsedTokens = total }

        var events: [AgentStreamEvent.Payload] = []
        let ok = json["status"] as? String == "success"
        if !ok {
            let error = json["error"] as? [String: Any]
            events.append(.notice(text: error?["message"] as? String ?? "Gemini CLI could not finish the turn."))
        }
        let duration = (stats["duration_ms"] as? Double).map { $0 / 1000 }
        events.append(.turnFinished(summary: AgentTurnSummary(
            ok: ok, inputTokens: input, outputTokens: output, duration: duration, model: model
        )))
        return events
    }

    // MARK: - Tools

    private func toolStarted(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        guard let id = json["tool_id"] as? String, let name = json["tool_name"] as? String else { return [] }
        let input = json["parameters"] as? [String: Any] ?? [:]
        let filePath = input["file_path"] as? String ?? input["absolute_path"] as? String
        let (title, detail) = Self.describe(name, input: input, filePath: filePath)
        var plan: [AgentPlanStep]?
        if name == "write_todos", let todos = input["todos"] as? [[String: Any]] {
            plan = todos.compactMap { todo in
                guard let text = todo["description"] as? String else { return nil }
                return AgentPlanStep(text: text, status: AgentPlanStep.status(from: todo["status"] as? String))
            }
        }
        return [.toolStarted(call: AgentToolCall(
            id: id, name: name, title: title, detail: detail, filePath: filePath, plan: plan
        ))]
    }

    private static func describe(
        _ name: String, input: [String: Any], filePath: String?
    ) -> (String, String?) {
        switch name {
        case "run_shell_command": ("Command", input["command"] as? String)
        case "read_file", "read_many_files": ("Read", filePath)
        case "write_file": ("Write", filePath)
        case "replace", "edit": ("Edit", filePath)
        case "glob", "search_file_content", "grep_search": ("Search", input["pattern"] as? String)
        case "list_directory": ("List", input["dir_path"] as? String ?? input["path"] as? String)
        case "web_fetch": ("Fetch", input["prompt"] as? String)
        case "google_web_search": ("Search the web", input["query"] as? String)
        case "write_todos": ("Plan", nil)
        default: (name.replacingOccurrences(of: "_", with: " ").capitalized, nil)
        }
    }

    private func toolFinished(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        guard let id = json["tool_id"] as? String else { return [] }
        let ok = json["status"] as? String == "success"
        let error = json["error"] as? [String: Any]
        let raw = ok ? json["output"] as? String : error?["message"] as? String ?? json["output"] as? String
        let (kept, truncated) = raw.map { AgentLimits.trimmed($0, to: AgentLimits.maximumToolOutputBytes) }
            ?? ("", false)
        return [.toolFinished(callID: id, ok: ok, output: kept.isEmpty ? nil : kept, truncated: truncated)]
    }

    private mutating func ignore(_ name: String) -> [AgentStreamEvent.Payload] {
        guard announcedUnknownNames.insert(name).inserted else { return [] }
        return [.notice(text: "Gemini CLI sent something this app does not know how to show (\(name)).")]
    }
}
