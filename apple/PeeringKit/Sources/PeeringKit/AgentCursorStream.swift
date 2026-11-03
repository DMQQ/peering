import Foundation
import RemoteCore

/// Cursor CLI's `--print --output-format stream-json` lines, turned into the app's own events.
///
/// A tool call is an object keyed by the tool's kind (`readToolCall`, `shellToolCall`, ...), each
/// with `args` and, once completed, a `result` holding `success` or not.
public struct AgentCursorStream {
    public static let agentID = "cursor-agent"

    private let directory: String

    public init(directory: String, cliSessionID: String? = nil) {
        self.directory = directory
        self.cliSessionID = cliSessionID
    }

    public private(set) var cliSessionID: String?
    private var inTurn = false
    private var model: String?
    private var announcedUnknownNames: Set<String> = []

    public mutating func receive(line: String) -> [AgentStreamEvent.Payload] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return [.notice(text: "A line of Cursor's output could not be read.")]
        }

        var events = noteSession(json)
        switch type {
        case "system", "user":
            break
        case "assistant":
            let message = json["message"] as? [String: Any]
            let parts = message?["content"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["text"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { break }
            events += beginTurnIfNeeded()
            let (kept, truncated) = AgentLimits.trimmed(text, to: AgentLimits.maximumToolOutputBytes)
            events.append(.textFinal(text: kept))
            if truncated { events.append(.notice(text: "Part of a reply was too long to show.")) }
        case "tool_call":
            events += beginTurnIfNeeded() + tool(json)
        case "result":
            events += beginTurnIfNeeded() + finish(json)
        default:
            events += ignore(type)
        }
        return events
    }

    private mutating func noteSession(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        if json["type"] as? String == "system" { model = json["model"] as? String ?? model }
        guard let id = json["session_id"] as? String, id != cliSessionID else { return [] }
        cliSessionID = id
        return [.sessionReady(agentID: Self.agentID, cliSessionID: id, model: model, directory: directory)]
    }

    private mutating func beginTurnIfNeeded() -> [AgentStreamEvent.Payload] {
        guard !inTurn else { return [] }
        inTurn = true
        return [.turnStarted]
    }

    private mutating func finish(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        inTurn = false
        let failed = json["is_error"] as? Bool == true || json["subtype"] as? String != "success"
        var events: [AgentStreamEvent.Payload] = []
        if failed {
            events.append(.notice(text: json["result"] as? String ?? "Cursor could not finish the turn."))
        }
        let duration = (json["duration_ms"] as? Double).map { $0 / 1000 }
        events.append(.turnFinished(summary: AgentTurnSummary(ok: !failed, duration: duration, model: model)))
        return events
    }

    // MARK: - Tools

    private func tool(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        guard let id = json["call_id"] as? String,
              let call = json["tool_call"] as? [String: Any],
              let kind = call.keys.first
        else { return [] }
        let body = call[kind] as? [String: Any] ?? [:]
        let name = kind.hasSuffix("ToolCall") ? String(kind.dropLast("ToolCall".count)) : kind
        let input = body["args"] as? [String: Any] ?? [:]

        if json["subtype"] as? String == "started" {
            let filePath = input["path"] as? String
            let (title, detail) = Self.describe(name, input: input, filePath: filePath, body: body)
            return [.toolStarted(call: AgentToolCall(
                id: id, name: name, title: title, detail: detail, filePath: filePath
            ))]
        }
        guard json["subtype"] as? String == "completed" else { return [] }
        let result = body["result"] as? [String: Any] ?? [:]
        let success = result["success"] as? [String: Any]
        let quiet: Set<String> = ["read", "write", "edit", "delete", "updateTodos"]
        var raw: String?
        if let success {
            raw = quiet.contains(name) ? nil : success["stdout"] as? String ?? success["output"] as? String
        } else {
            let failure = result.values.first as? [String: Any]
            raw = failure?["error"] as? String ?? failure?["message"] as? String ?? failure?["stderr"] as? String
        }
        let (kept, truncated) = raw.map { AgentLimits.trimmed($0, to: AgentLimits.maximumToolOutputBytes) }
            ?? ("", false)
        return [.toolFinished(callID: id, ok: success != nil, output: kept.isEmpty ? nil : kept, truncated: truncated)]
    }

    private static func describe(
        _ name: String, input: [String: Any], filePath: String?, body: [String: Any]
    ) -> (String, String?) {
        switch name {
        case "shell": ("Command", input["command"] as? String)
        case "read": ("Read", filePath)
        case "write": ("Write", filePath)
        case "edit": ("Edit", filePath)
        case "delete": ("Delete", filePath)
        case "grep", "glob": ("Search", input["pattern"] as? String ?? input["globPattern"] as? String)
        case "ls": ("List", filePath)
        case "updateTodos": ("Plan", nil)
        case "function": (body["name"] as? String ?? "Tool", nil)
        default: (name.prefix(1).uppercased() + name.dropFirst(), nil)
        }
    }

    private mutating func ignore(_ name: String) -> [AgentStreamEvent.Payload] {
        guard announcedUnknownNames.insert(name).inserted else { return [] }
        return [.notice(text: "Cursor sent something this app does not know how to show (\(name)).")]
    }
}
