import Foundation
import RemoteCore

/// Claude Code's stream-json lines, turned into the app's own events.
///
/// A value fed one line at a time: the host owns the process and the line buffering, so everything
/// here is a pure function of the bytes and the state so far, which is what makes the two CLIs'
/// quirks testable without a process or a network.
///
/// The shapes were captured from Claude Code 2.1.289 (`claude -p --input-format stream-json
/// --output-format stream-json --verbose --include-partial-messages --replay-user-messages
/// --permission-prompt-tool stdio`), not from documentation: the SDK's types and a live run
/// disagree with the prose in places.
public struct AgentClaudeStream {
    public init() {}

    /// The CLI's own session id, captured from the init line, for resuming after a restart.
    public private(set) var cliSessionID: String?

    /// Types this build has already said it does not know, so a chatty unknown does not fill the
    /// transcript with the same line.
    private var announcedUnknownTypes: Set<String> = []

    /// The session's running cost, which the CLI reports as a total and the pill shows as a turn.
    private var lastTotalCostUSD: Double?

    /// What each waiting approval asked for, kept so the answer can echo the tool's input back.
    ///
    /// The CLI documents an allow as carrying the input it is applying, and the input only exists
    /// on the request line, so it is kept here for the moment between the ask and the answer.
    private var approvalInputs: [String: [String: Any]] = [:]

    /// The input of a waiting approval, taken so it is not held after it can no longer be used.
    public mutating func takeApprovalInput(_ approvalID: String) -> [String: Any]? {
        approvalInputs.removeValue(forKey: approvalID)
    }

    /// What the init line said, used when a later line wants to repeat it.
    private var model: String?

    /// Everything the line means, in order. Empty for the lines that mean nothing to a reader.
    public mutating func receive(line: String) -> [AgentStreamEvent.Payload] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return [.notice(text: "A line of Claude Code's output could not be read.")]
        }

        // Subagent traffic rides the same stream. Nothing here draws it: its ids name a
        // conversation the user is not looking at, and a card that belongs to a subagent reads as
        // the main one doing something it did not do.
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
        case "control_request":
            return controlRequest(json)
        case "control_response", "control_cancel_request":
            // The CLI's answers to this side's own control requests (an interrupt's receipt, an
            // ask it is no longer waiting on). Machinery, not conversation.
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
            // Progress meters and status chatter, none of which is a sentence for a reader.
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
            // Thinking deltas, tool-input deltas and the block markers. The text they build is
            // also sent whole, and the whole copy is the one the transcript keeps.
            return []
        }
        return [.textDelta(text: text)]
    }

    private mutating func assistant(_ json: [String: Any]) -> [AgentStreamEvent.Payload] {
        guard let message = json["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return [] }

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
        // The CLI reports the session's total, and the pill is about this turn: the difference is
        // what this turn cost. A total that moved backwards is a reset (`/clear`), and then the
        // total is the turn.
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
        // The tool's own sentence about what it is asking, which is what the bar shows above the
        // buttons. The command itself is already the card's detail.
        let reason = (input["description"] as? String) ?? (request["decision_reason"] as? String)
        return [.approvalRequested(approvalID: approvalID, call: call, reason: reason)]
    }

    /// A type this build has nothing to say about, said once.
    private mutating func ignore(_ type: String) -> [AgentStreamEvent.Payload] {
        guard announcedUnknownTypes.insert(type).inserted else { return [] }
        return [.notice(text: "Claude Code sent something this app does not know how to show (\(type)).")]
    }

    // MARK: - Shapes

    /// One tool call as the card will draw it.
    ///
    /// The input keys are the CLI's own, per tool, which is why this is a table and not a decoder:
    /// a tool this build has never heard of still becomes a card, with its name and no detail.
    static func call(
        id: String,
        name: String,
        input: [String: Any],
        displayName: String? = nil
    ) -> AgentToolCall {
        // A question ask is the one call whose *content* is the ask: the card shows the question
        // and the choices, and the answer travels back as the chosen label.
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
        // The proposed change is known before it is approved, and showing it is the point of an
        // approval card that is not just a yes button.
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
