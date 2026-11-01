import Foundation

/// Which saved chats stop coming back as active when the Mac starts. A Claude chat untouched for a week leaves the list and is found in History, which lists Claude Code's own copy of the conversation once no active chat holds it. A chat History cannot continue (Codex, OpenCode) stays, since retiring it would lose it.
public enum AgentChatRetirement {
    public static let idleLimit: TimeInterval = 7 * 24 * 60 * 60

    public static func isRetired(agentID: String, cliSessionID: String?, lastActivity: Date, now: Date) -> Bool {
        guard agentID == "claude", cliSessionID != nil else { return false }
        return now.timeIntervalSince(lastActivity) > idleLimit
    }
}
