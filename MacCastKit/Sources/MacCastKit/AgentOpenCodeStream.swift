import Foundation
import RemoteCore

/// OpenCode's `run --format json` lines, turned into the app's own events.
public struct AgentOpenCodeStream {
    private let directory: String

    public init(directory: String, cliSessionID: String? = nil) {
        self.directory = directory
        self.cliSessionID = cliSessionID
    }

    public private(set) var cliSessionID: String?

    /// What the session has used. The context window is not in the stream: the adapter fills it
    /// from the model's own listing.
    public private(set) var usage = AgentUsage()
    private var inTurn = false
    private var inputTokens = 0
    private var outputTokens = 0
    private var announcedUnknownNames: Set<String> = []

    public mutating func receive(line: String) -> [AgentStreamEvent.Payload] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return [.notice(text: "A line of OpenCode's output could not be read.")]
        }

        var events: [AgentStreamEvent.Payload] = []
        if let id = json["sessionID"] as? String, id != cliSessionID {
            cliSessionID = id
            events.append(.sessionReady(
                agentID: "opencode", cliSessionID: id, model: nil, directory: directory
            ))
        }
        let part = json["part"] as? [String: Any] ?? [:]

        switch type {
        case "step_start":
            events += beginTurnIfNeeded()
        case "text":
            guard let text = part["text"] as? String, !text.isEmpty else { return events }
            events += beginTurnIfNeeded()
            let (kept, truncated) = AgentLimits.trimmed(text, to: AgentLimits.maximumToolOutputBytes)
            events.append(.textFinal(text: kept))
            if truncated { events.append(.notice(text: "Part of a reply was too long to show.")) }
        case "tool_use":
            events += beginTurnIfNeeded()
            events += tool(part)
        case "step_finish":
            let tokens = part["tokens"] as? [String: Any]
            inputTokens += tokens?["input"] as? Int ?? 0
            outputTokens += tokens?["output"] as? Int ?? 0
            noteStepUsage(tokens)
            if part["reason"] as? String != "tool-calls" {
                events += beginTurnIfNeeded()
                events.append(finishTurn(ok: true))
            }
        case "error":
            events += beginTurnIfNeeded()
            events.append(.notice(text: Self.errorText(json["error"])))
            events.append(finishTurn(ok: false))
        case "reasoning":
            break
        default:
            events += ignore("line/\(type)")
        }
        return events
    }

    private mutating func noteStepUsage(_ tokens: [String: Any]?) {
        guard let tokens else { return }
        let cache = tokens["cache"] as? [String: Any]
        let input = tokens["input"] as? Int ?? 0
        let read = cache?["read"] as? Int ?? 0
        let write = cache?["write"] as? Int ?? 0
        let output = tokens["output"] as? Int ?? 0
        usage.inputTokens += input + write
        usage.cachedTokens += read
        usage.outputTokens += output
        usage.contextUsedTokens = input + read + write + output
    }

    // MARK: - Turns

    private mutating func beginTurnIfNeeded() -> [AgentStreamEvent.Payload] {
        guard !inTurn else { return [] }
        inTurn = true
        return [.turnStarted]
    }

    private mutating func finishTurn(ok: Bool) -> AgentStreamEvent.Payload {
        let summary = AgentTurnSummary(
            ok: ok,
            inputTokens: inputTokens > 0 ? inputTokens : nil,
            outputTokens: outputTokens > 0 ? outputTokens : nil
        )
        inTurn = false
        inputTokens = 0
        outputTokens = 0
        return .turnFinished(summary: summary)
    }

    // MARK: - Tools

    private func tool(_ part: [String: Any]) -> [AgentStreamEvent.Payload] {
        guard let name = part["tool"] as? String,
              let id = part["callID"] as? String ?? part["id"] as? String
        else { return [] }
        let state = part["state"] as? [String: Any] ?? [:]
        let input = state["input"] as? [String: Any] ?? [:]
        let metadata = state["metadata"] as? [String: Any]
        let filePath = input["filePath"] as? String

        let title: String
        let detail: String?
        switch name {
        case "bash": (title, detail) = ("Command", input["command"] as? String)
        case "read": (title, detail) = ("Read", filePath)
        case "write": (title, detail) = ("Write", filePath)
        case "edit", "patch", "multiedit": (title, detail) = ("Edit", filePath)
        case "glob", "grep": (title, detail) = ("Search", input["pattern"] as? String)
        case "list": (title, detail) = ("List", input["path"] as? String)
        case "webfetch": (title, detail) = ("Fetch", input["url"] as? String)
        case "task": (title, detail) = ("Agent", input["description"] as? String)
        case "todowrite", "todoread": (title, detail) = ("Plan", nil)
        default: (title, detail) = (name.prefix(1).uppercased() + name.dropFirst(), nil)
        }

        var plan: [AgentPlanStep]?
        if name == "todowrite", let todos = input["todos"] as? [[String: Any]] {
            let steps = todos.compactMap { todo -> AgentPlanStep? in
                guard let text = todo["content"] as? String else { return nil }
                return AgentPlanStep(text: text, status: AgentPlanStep.status(from: todo["status"] as? String))
            }
            plan = steps.isEmpty ? nil : steps
        }

        var diff: String?
        if name == "edit", let unified = metadata?["diff"] as? String {
            diff = AgentLimits.trimmed(unified, to: AgentLimits.maximumToolOutputBytes).text
        }

        let ok = state["status"] as? String == "completed"
        let quiet: Set<String> = ["read", "write", "edit", "patch", "multiedit", "todowrite", "todoread"]
        let raw = ok ? (quiet.contains(name) ? nil : state["output"] as? String) : state["error"] as? String
        let (kept, truncated) = raw.map { AgentLimits.trimmed($0, to: AgentLimits.maximumToolOutputBytes) }
            ?? ("", false)

        return [
            .toolStarted(call: AgentToolCall(
                id: id, name: name, title: title, detail: detail, filePath: filePath, diff: diff, plan: plan
            )),
            .toolFinished(
                callID: id,
                ok: ok,
                output: kept.isEmpty ? nil : kept,
                truncated: truncated
            ),
        ]
    }

    // MARK: - Unknowns and errors

    private mutating func ignore(_ name: String) -> [AgentStreamEvent.Payload] {
        guard announcedUnknownNames.insert(name).inserted else { return [] }
        return [.notice(text: "OpenCode sent something this app does not know how to show (\(name)).")]
    }

    static func errorText(_ value: Any?) -> String {
        guard let object = value as? [String: Any] else { return "OpenCode reported an error." }
        let data = object["data"] as? [String: Any]
        if let message = data?["message"] as? String, !message.isEmpty { return message }
        if let name = object["name"] as? String { return "OpenCode reported an error (\(name))." }
        return "OpenCode reported an error."
    }
}
