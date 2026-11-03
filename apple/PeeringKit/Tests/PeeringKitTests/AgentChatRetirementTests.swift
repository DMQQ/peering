import Foundation
import PeeringKit
import Testing

@Suite struct AgentChatRetirementTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
    private let eightDays: TimeInterval = 8 * 24 * 60 * 60

    @Test func aClaudeChatIdleForOverAWeekRetires() {
        #expect(AgentChatRetirement.isRetired(agentID: "claude", cliSessionID: "abc", lastActivity: now - eightDays, now: now))
    }

    @Test func aRecentChatStays() {
        #expect(!AgentChatRetirement.isRetired(agentID: "claude", cliSessionID: "abc", lastActivity: now - 3600, now: now))
    }

    @Test func aChatHistoryCannotContinueStays() {
        #expect(!AgentChatRetirement.isRetired(agentID: "codex", cliSessionID: "abc", lastActivity: now - eightDays, now: now))
        #expect(!AgentChatRetirement.isRetired(agentID: "claude", cliSessionID: nil, lastActivity: now - eightDays, now: now))
    }
}
