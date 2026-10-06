import Foundation
import RemoteCore

/// Codex's `exec --json` lines, turned into the app's own events.
///
/// The shapes were captured from codex-cli 0.157.1 (`codex exec --json --sandbox workspace-write
/// --skip-git-repo-check -m <model> "<prompt>"`, and the same with `exec resume <thread_id>`).
///
/// Two facts shape this parser. One process serves one turn, so `thread.started` on a resume
/// repeats the id the first turn already gave, and a turn that ends is not a session that ended:
/// the thread stays resumable. And exec mode has no approval channel at all, so nothing here ever
/// produces an approval: what the sandbox allows is what runs.
public struct AgentCodexStream {
    /// The folder the session runs in. Codex never says: it is the cwd the host spawned it with,
    /// which is the one thing this side knows and the CLI does not repeat.
    private let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    public private(set) var cliSessionID: String?
    private var announcedUnknownNames: Set<String> = []
    private var lastErrorMessage: String?

    public mutating func receive(line: String) -> [AgentStreamEvent.Payload] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return [.notice(text: "A line of Codex's output could not be read.")]
        }

        switch type {
        case "thread.started":
            cliSessionID = json["thread_id"] as? String
            return [
                .sessionReady(
                    agentID: "codex",
                    cliSessionID: cliSessionID,
                    model: nil,
                    directory: directory
                )
            ]
        case "turn.started":
            return [.turnStarted]
        case "item.started":
            return item(json, started: true)
        case "item.completed":
            return item(json, started: false)
        case "item.updated":
            // The plan branch's incremental updates; the started and completed edges carry enough.
            return []
        case "turn.completed":
            let usage = json["usage"] as? [String: Any]
            return [
                .turnFinished(
                    summary: AgentTurnSummary(
                        ok: true,
                        inputTokens: usage?["input_tokens"] as? Int,
                        outputTokens: usage?["output_tokens"] as? Int
                    )
                )
            ]
        case "turn.failed":
            let message = Self.errorText(json["error"])
            let notice = message == lastErrorMessage ? [] : [AgentStreamEvent.Payload.notice(text: message)]
            lastErrorMessage = message
            return [.turnFinished(summary: AgentTurnSummary(ok: false))] + notice
        case "error":
            let message = Self.errorText(json)
            guard message != lastErrorMessage else { return [] }
            lastErrorMessage = message
            return [.notice(text: message)]
        default:
            return ignore("line/\(type)")
        }
    }

    // MARK: - Items

    private mutating func item(_ json: [String: Any], started: Bool) -> [AgentStreamEvent.Payload] {
        guard let item = json["item"] as? [String: Any],
              let id = item["id"] as? String,
              let kind = item["type"] as? String
        else { return [] }

        switch kind {
        case "agent_message":
            // The whole message, and the only edge it has: no item.started is sent for these.
            guard !started, let text = item["text"] as? String, !text.isEmpty else { return [] }
            let (kept, truncated) = AgentLimits.trimmed(text, to: AgentLimits.maximumToolOutputBytes)
            return truncated
                ? [.textFinal(text: kept), .notice(text: "Part of a reply was too long to show.")]
                : [.textFinal(text: kept)]

        case "reasoning":
            // Sent whole at completion; dropped like Claude's thinking in this version.
            return []

        case "command_execution":
            let command = item["command"] as? String
            if started {
                return [.toolStarted(call: AgentToolCall(
                    id: id, name: kind, title: "Command", detail: command
                ))]
            }
            let output = item["aggregated_output"] as? String ?? ""
            let (kept, truncated) = AgentLimits.trimmed(output, to: AgentLimits.maximumToolOutputBytes)
            let status = item["status"] as? String
            let exit = item["exit_code"] as? Int
            return [.toolFinished(
                callID: id,
                ok: status == "completed" && (exit ?? 0) == 0,
                output: kept.isEmpty ? nil : kept,
                truncated: truncated
            )]

        case "file_change":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            let summary = changes.map { change in
                "\(change["kind"] as? String ?? "update") \(change["path"] as? String ?? "")"
            }.joined(separator: "\n")
            if started {
                return [.toolStarted(call: AgentToolCall(
                    id: id,
                    name: kind,
                    title: "Edit",
                    // The kind first, then the first path: a card with three files says what it
                    // did and where, and the rest is in the output.
                    detail: paths.first,
                    filePath: paths.first
                    // No diff: this CLI's file-change items carry none in this version, unlike
                    // Claude's edit inputs. The paths and the kinds are what there is to show.
                ))]
            }
            return [.toolFinished(
                callID: id,
                ok: item["status"] as? String == "completed",
                output: summary.isEmpty ? nil : summary,
                truncated: false
            )]

        case "mcp_tool_call":
            let server = item["server"] as? String
            let tool = item["tool"] as? String
            let detail = [server, tool].compactMap { $0 }.joined(separator: " · ")
            if started {
                return [.toolStarted(call: AgentToolCall(
                    id: id, name: kind, title: "MCP tool", detail: detail.isEmpty ? nil : detail
                ))]
            }
            let error = Self.plainText(item["error"])
            return [.toolFinished(callID: id, ok: error == nil, output: error, truncated: false)]

        case "web_search":
            if started {
                return [.toolStarted(call: AgentToolCall(
                    id: id, name: kind, title: "Search", detail: item["query"] as? String
                ))]
            }
            return [.toolFinished(callID: id, ok: true, output: nil, truncated: false)]

        case "todo_list":
            let todos = (item["items"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            if started {
                return [.toolStarted(call: AgentToolCall(
                    id: id, name: kind, title: "Plan", detail: todos.isEmpty ? nil : todos.joined(separator: "; ")
                ))]
            }
            return [.toolFinished(callID: id, ok: true, output: nil, truncated: false)]

        case "error":
            // A non-fatal warning the CLI draws as an item, such as a model-metadata miss.
            guard !started, let message = item["message"] as? String else { return [] }
            return [.notice(text: message)]

        default:
            return ignore("item/\(kind)")
        }
    }

    private mutating func ignore(_ name: String) -> [AgentStreamEvent.Payload] {
        guard announcedUnknownNames.insert(name).inserted else { return [] }
        return [.notice(text: "Codex sent something this app does not know how to show (\(name)).")]
    }

    // MARK: - Error text

    /// Codex reports API failures as a JSON document inside a string field, so the sentence a user
    /// can read is one layer down. A message that is not that shape is its own text.
    static func errorText(_ value: Any?) -> String {
        guard let object = value as? [String: Any], let raw = object["message"] as? String else {
            return "Codex reported an error."
        }
        if let data = raw.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = (nested["error"] as? [String: Any])?["message"] as? String {
            return message
        }
        return raw
    }

    private static func plainText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        return nil
    }
}
