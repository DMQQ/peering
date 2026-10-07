import Foundation

public enum AgentModelName {
    /// `claude-opus-4-1-20250805` reads as `opus-4-1`: the vendor prefix and the dated build suffix say nothing at a glance.
    public static func short(_ name: String) -> String {
        var short = name.hasPrefix("claude-") ? String(name.dropFirst("claude-".count)) : name
        if let dash = short.lastIndex(of: "-") {
            let tail = short[short.index(after: dash)...]
            if tail.count == 8, tail.allSatisfy(\.isNumber) { short = String(short[..<dash]) }
        }
        return short
    }

    /// The CLI answers an alias with a dated full name, so a choice is the current model when the name contains it.
    public static func isCurrent(_ choice: String, current: String?) -> Bool {
        current?.contains(choice) == true
    }

    /// Claude's are the CLI's documented aliases; Codex's come from the Mac, and anything else is typed in through Custom.
    public static func suggestions(agentID: String, hostChoices: [String]) -> [String] {
        agentID == "claude" ? ["sonnet", "opus", "haiku"] : hostChoices
    }

    public static func offersPicker(agentID: String, hostSupportsPicker: Bool) -> Bool {
        hostSupportsPicker && (agentID == "claude" || agentID == "codex")
    }
}
