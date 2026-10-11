import Foundation
import RemoteCore

/// Reads a session file Claude Code wrote itself (`~/.claude/projects/<folder>/<id>.jsonl`), so a conversation started in a terminal can be listed and continued from the phone.
public enum AgentClaudeSessionFile {
    public struct Summary: Equatable, Sendable {
        public let directory: String
        public let title: String
    }

    private static let titleLength = 80

    /// The folder and a title from the start and end of a file. A file is megabytes, and the folder is on its first lines while the CLI's own title is written late.
    public static func summary(head: String, tail: String) -> Summary? {
        var directory: String?
        var firstPrompt: String?
        var aiTitle: String?
        for object in objects(in: head) + objects(in: tail) {
            if directory == nil, let cwd = object["cwd"] as? String, cwd.hasPrefix("/") { directory = cwd }
            if firstPrompt == nil, let prompt = prompt(in: object) { firstPrompt = prompt }
            if object["type"] as? String == "ai-title", let title = object["aiTitle"] as? String, !title.isEmpty {
                aiTitle = title
            }
        }
        guard let directory, let title = aiTitle ?? firstPrompt else { return nil }
        return Summary(directory: directory, title: shortened(title))
    }

    /// The conversation as the chat screen reads it: what was asked, what was said, and each tool call with its outcome.
    ///
    /// Side-chains (sub-agents) and the CLI's bookkeeping lines are left out; a tool call's result is matched by the same `tool_use_id` the live stream uses.
    public static func events(from text: String) -> [AgentStreamEvent.Payload] {
        var stream = AgentClaudeStream()
        var payloads: [AgentStreamEvent.Payload] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = object(in: line), object["isSidechain"] as? Bool != true else { continue }
            switch object["type"] as? String {
            case "user":
                if let prompt = prompt(in: object) {
                    payloads.append(.userPrompt(text: prompt))
                } else if object["isMeta"] as? Bool != true {
                    payloads += stream.receive(line: String(line))
                }
            case "assistant":
                payloads += stream.receive(line: String(line))
            default:
                continue
            }
        }
        return payloads
    }

    /// What the file says the session has used: the size of the conversation at its last call, and the tokens of every call after the first reading of each message. A resumed chat has no process to report this until its next turn, and the usage sheet would be empty meanwhile. The window and limits are only the CLI's to say, so they stay absent.
    public static func usage(from text: String) -> AgentUsage? {
        var usage = AgentUsage()
        var seen = Set<String>()
        var found = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = object(in: line), object["type"] as? String == "assistant",
                  object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any],
                  let used = message["usage"] as? [String: Any]
            else { continue }
            let input = used["input_tokens"] as? Int ?? 0
            let cacheRead = used["cache_read_input_tokens"] as? Int ?? 0
            let cacheWrite = used["cache_creation_input_tokens"] as? Int ?? 0
            let output = used["output_tokens"] as? Int ?? 0
            let context = input + cacheRead + cacheWrite + output
            guard context > 0 else { continue }
            usage.contextUsedTokens = context
            found = true
            // One message is written once per content block, each with the same usage: counted once.
            if let id = message["id"] as? String, !seen.insert(id).inserted { continue }
            usage.inputTokens += input + cacheWrite
            usage.cachedTokens += cacheRead
            usage.outputTokens += output
        }
        return found ? usage : nil
    }

    /// The replay with its loose ends tied: a file read back belongs to a process that is gone, so a tool call it never saw finish ends as failed and the last turn is closed. Left open, the chat reads as working for ever and the composer waits on a reply that cannot come.
    public static func settled(_ events: [AgentStreamEvent.Payload]) -> [AgentStreamEvent.Payload] {
        var openCalls: [String] = []
        for event in events {
            switch event {
            case .toolStarted(let call): openCalls.append(call.id)
            case .toolFinished(let callID, _, _, _): openCalls.removeAll { $0 == callID }
            default: break
            }
        }
        let closing = openCalls.map { AgentStreamEvent.Payload.toolFinished(callID: $0, ok: false, output: nil, truncated: false) }
        return events + closing + [.turnFinished(summary: AgentTurnSummary(ok: true))]
    }

    /// What a person typed: a plain string or text blocks, not a tool result, and not the wrapper lines the CLI writes around its own slash commands.
    static func prompt(in object: [String: Any]) -> String? {
        guard object["type"] as? String == "user", object["isMeta"] as? Bool != true,
              object["isSidechain"] as? Bool != true,
              let message = object["message"] as? [String: Any]
        else { return nil }
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return trimmed
    }

    private static func shortened(_ title: String) -> String {
        let line = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? title
        guard line.count > titleLength else { return line }
        return String(line.prefix(titleLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Whole lines only: a window cut out of a file begins and ends mid-line.
    private static func objects(in window: String) -> [[String: Any]] {
        window.split(separator: "\n", omittingEmptySubsequences: true).compactMap { object(in: $0) }
    }

    private static func object(in line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
