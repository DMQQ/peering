import Foundation
import RemoteCore

public struct AgentClaudeStream {
    public init() {}

    public private(set) var cliSessionID: String?

    /// What the session has used, as far as the stream has said. Read by the adapter after each line.
    public private(set) var usage = AgentUsage()

    /// Types this build has already said it does not know, so a chatty unknown does not fill the
    /// transcript with the same line.
    private var announcedUnknownTypes: Set<String> = []

    private var lastTotalCostUSD: Double?

    /// What each waiting approval asked for, kept so the answer can echo the tool's input back.
    private var approvalInputs: [String: [String: Any]] = [:]

    public mutating func takeApprovalInput(_ approvalID: String) -> [String: Any]? {
        approvalInputs.removeValue(forKey: approvalID)
    }

    private var model: String?

    /// Everything the line means, in order. Empty for the lines that mean nothing to a reader.
    public mutating func receive(line: String) -> [AgentStreamEvent.Payload] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return [.notice(text: "A line of Claude Code's output could not be read.")]
        }

        if let parent = json["parent_tool_use_id"] as? String, !parent.isEmpty {
            return []
        }

        switch type {
        case "system":
            return system(json)
        case "stream_event":
            return streamEvent(json)
        case "assistant":
            return assistant(json)
        case "user":
            return user(json)
        case "result":
            return result(json)
        case "rate_limit_event":
            noteLimits(json["rate_limit_info"] as? [String: Any])
            return []
        case "control_request":
            return controlRequest(json)
        case "control_response", "control_cancel_request":
            return []
        default:
            return ignore(type)
        }
    }

    // MARK: - Line kinds

    private mutating func system(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        switch json["subtype"] as? String {
        case "init":
            cliSessionID = json["session_id"] as? String
            model = json["model"] as? String
            return [
                .sessionReady(
                    agentID: "claude",
                    cliSessionID: cliSessionID,
                    model: model,
                    directory: json["cwd"] as? String ?? ""
                )
            ]
        case "compact_boundary":
            return [.notice(text: "The conversation was compacted to fit.")]
        case "api_retry":
            return [.notice(text: "Claude Code is retrying after an API error.")]
        case "permission_denied":
            return [.notice(text: "Claude Code denied a tool call by its own rules.")]
        case "status", "thinking_tokens", "informational", "worker_shutting_down":
            return []
        default:
            return []
        }
    }

    private mutating func streamEvent(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        guard let event = json["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String, !text.isEmpty
        else {
            return []
        }
        return [.textDelta(text: text)]
    }

    private mutating func assistant(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        guard let message = json["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return [] }

        // The size of the conversation at this call, which is what the next one starts from.
        if let used = message["usage"] as? [String: Any] {
            let tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"]
                .reduce(0) { $0 + (used[$1] as? Int ?? 0) }
            if tokens > 0 { usage.contextUsedTokens = tokens }
        }

        var payloads: [AgentStreamEvent.Payload] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String, !text.isEmpty else { continue }
                let (kept, truncated) = AgentLimits.trimmed(text, to: AgentLimits.maximumToolOutputBytes)
                payloads.append(.textFinal(text: kept))
                if truncated {
                    payloads.append(.notice(text: "Part of a reply was too long to show."))
                }
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                payloads.append(.toolStarted(call: Self.call(id: id, name: name, input: block["input"] as? [String: Any] ?? [:])))
            default:
                continue
            }
        }
        return payloads
    }

    private mutating func user(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        // This CLI echoes the prompt it was sent (`--replay-user-messages`). The host writes the
        // prompt into the transcript when it sends one, for both CLIs alike, so the echo is a
        // second telling of something already said, not a source.
        if json["isReplay"] as? Bool == true { return [] }

        guard let message = json["message"] as? [String: Any] else { return [] }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var payloads: [AgentStreamEvent.Payload] = []
        for block in blocks where block["type"] as? String == "tool_result" {
            guard let callID = block["tool_use_id"] as? String else { continue }
            let output = Self.text(of: block["content"])
            let (kept, truncated) = AgentLimits.trimmed(output, to: AgentLimits.maximumToolOutputBytes)
            payloads.append(
                .toolFinished(
                    callID: callID,
                    ok: block["is_error"] as? Bool != true,
                    output: kept.isEmpty ? nil : kept,
                    truncated: truncated
                )
            )
        }
        return payloads
    }

    private mutating func result(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        let total = json["total_cost_usd"] as? Double
        var cost: Double?
        if let total {
            if let last = lastTotalCostUSD, total >= last {
                cost = total - last
            } else {
                cost = total
            }
            lastTotalCostUSD = total
        }
        let usage = json["usage"] as? [String: Any]
        noteTurnUsage(usage, cumulativeCostUSD: total, modelUsage: json["modelUsage"] as? [String: Any])
        let reason = json["terminal_reason"] as? String
        let summary = AgentTurnSummary(
            ok: json["is_error"] as? Bool != true,
            stopped: reason?.hasPrefix("aborted") == true,
            costUSD: cost,
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int,
            duration: (json["duration_ms"] as? Double).map { $0 / 1000 },
            model: (json["modelUsage"] as? [String: Any])?.keys.first ?? model
        )
        return [.turnFinished(summary: summary)]
    }

    /// A turn's tokens are added to the session's; the cost is already the session's running total.
    private mutating func noteTurnUsage(
        _ turn: [String: Any]?, cumulativeCostUSD: Double?, modelUsage: [String: Any]?
    ) {
        if let turn {
            usage.inputTokens += (turn["input_tokens"] as? Int ?? 0) + (turn["cache_creation_input_tokens"] as? Int ?? 0)
            usage.cachedTokens += turn["cache_read_input_tokens"] as? Int ?? 0
            usage.outputTokens += turn["output_tokens"] as? Int ?? 0
        }
        if let cumulativeCostUSD { usage.costUSD = cumulativeCostUSD }
        if let window = (modelUsage?.values.first as? [String: Any])?["contextWindow"] as? Int {
            usage.contextWindowTokens = window
        }
    }

    private static let limitOrder = ["five_hour", "seven_day"]

    private mutating func noteLimits(_ info: [String: Any]?) {
        guard let windows = info?["unifiedWindows"] as? [String: Any] else { return }
        let keys = windows.keys.sorted {
            (Self.limitOrder.firstIndex(of: $0) ?? Self.limitOrder.count, $0)
                < (Self.limitOrder.firstIndex(of: $1) ?? Self.limitOrder.count, $1)
        }
        usage.limits = keys.compactMap { key in
            guard let window = windows[key] as? [String: Any],
                  let used = window["utilization"] as? Double
            else { return nil }
            let label: String
            switch key {
            case "five_hour": label = "5 hours"
            case "seven_day": label = "7 days"
            default: label = key.replacingOccurrences(of: "_", with: " ")
            }
            return AgentUsageLimit(
                label: label,
                usedFraction: min(max(used, 0), 1),
                resetsAt: (window["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    private mutating func controlRequest(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        guard let request = json["request"] as? [String: Any],
              request["subtype"] as? String == "can_use_tool",
              let approvalID = json["request_id"] as? String,
              let name = request["tool_name"] as? String
        else {
            return ignore("control_request/\(((json["request"] as? [String: Any])?["subtype"] as? String) ?? "?")")
        }
        let input = request["input"] as? [String: Any] ?? [:]
        approvalInputs[approvalID] = input
        let id = request["tool_use_id"] as? String ?? approvalID
        let call = Self.call(
            id: id,
            name: name,
            input: input,
            displayName: request["display_name"] as? String
        )
        let reason = (input["description"] as? String) ?? (request["decision_reason"] as? String)
        return [.approvalRequested(approvalID: approvalID, call: call, reason: reason)]
    }

    private mutating func ignore(_ type: String) -> [AgentStreamEvent.Payload] {
        guard announcedUnknownTypes.insert(type).inserted else { return [] }
        return [.notice(text: "Claude Code sent something this app does not know how to show (\(type)).")]
    }

    // MARK: - Shapes

    /// One tool call as the card will draw it.
    static func call(
        id: String,
        name: String,
        input: [String: Any],
        displayName: String? = nil
    ) -> AgentToolCall {
        if name == "AskUserQuestion", let questions = input["questions"] as? [[String: Any]] {
            let first = questions.first
            let question = first?["question"] as? String
            var options: [AgentToolOption] = []
            for option in (first?["options"] as? [[String: Any]] ?? []) {
                guard let label = option["label"] as? String else { continue }
                options.append(AgentToolOption(label: label, detail: option["description"] as? String))
            }
            let detail: String?
            if questions.count > 1 {
                // Several questions in one ask cannot be answered by one tap, so the card says so
                // rather than offering a choice that would answer only the first.
                detail = [
                    question,
                    "This ask holds \(questions.count) questions; answer them in the terminal.",
                ].compactMap { $0 }.joined(separator: "\n\n")
            } else {
                detail = question
            }
            return AgentToolCall(
                id: id,
                name: name,
                title: (first?["header"] as? String) ?? "Question",
                detail: detail,
                options: options.isEmpty ? nil : options
            )
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
    private static func text(of content: Any?) -> String {
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
