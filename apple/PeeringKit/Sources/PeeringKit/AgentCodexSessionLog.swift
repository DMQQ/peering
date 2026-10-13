import Foundation
import RemoteCore

/// What Codex writes about a thread's usage in its own session log, which `exec --json` does not
/// repeat: the context window, the size of the conversation now, and the account's rate-limit
/// windows. The log is `~/.codex/sessions/<y>/<m>/<d>/rollout-…-<thread id>.jsonl`, and its last
/// `token_count` event is the current answer.
public enum AgentCodexSessionLog {
    /// The usage in the last `token_count` event of a log's text, or nil when it holds none.
    public static func usage(fromLog text: String) -> AgentUsage? {
        var last: [String: Any]?
        for line in text.split(separator: "\n") where line.contains("\"token_count\"") {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count"
            else { continue }
            last = payload
        }
        guard let payload = last else { return nil }

        var usage = AgentUsage()
        if let info = payload["info"] as? [String: Any] {
            let total = info["total_token_usage"] as? [String: Any]
            let input = total?["input_tokens"] as? Int ?? 0
            let cached = total?["cached_input_tokens"] as? Int ?? 0
            usage.inputTokens = max(input - cached, 0)
            usage.cachedTokens = cached
            usage.outputTokens = total?["output_tokens"] as? Int ?? 0
            usage.contextWindowTokens = info["model_context_window"] as? Int
            usage.contextUsedTokens = (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? Int
        }
        let limits = payload["rate_limits"] as? [String: Any]
        usage.limits = ["primary", "secondary"].compactMap { key in
            guard let window = limits?[key] as? [String: Any],
                  let percent = window["used_percent"] as? Double,
                  let minutes = window["window_minutes"] as? Int
            else { return nil }
            return AgentUsageLimit(
                label: label(forMinutes: minutes),
                usedFraction: min(max(percent / 100, 0), 1),
                resetsAt: (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            )
        }
        return usage
    }

    /// "5 hours", "7 days", "30 days": the window as a person says it.
    public static func label(forMinutes minutes: Int) -> String {
        if minutes >= 1440, minutes % 1440 == 0 {
            let days = minutes / 1440
            return days == 1 ? "1 day" : "\(days) days"
        }
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return "\(minutes) minutes"
    }
}
