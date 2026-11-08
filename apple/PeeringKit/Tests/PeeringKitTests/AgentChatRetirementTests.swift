import Foundation
import PeeringKit
import Testing

@Suite struct AgentChatRetirementTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
    private let thirteenHours: TimeInterval = 13 * 60 * 60
    private let elevenHours: TimeInterval = 11 * 60 * 60

    @Test func aClaudeChatIdleForOverTwelveHoursRetires() {
        #expect(AgentChatRetirement.isRetired(agentID: "claude", cliSessionID: "abc", lastActivity: now - thirteenHours, now: now))
    }

    @Test func aRecentChatStays() {
        #expect(!AgentChatRetirement.isRetired(agentID: "claude", cliSessionID: "abc", lastActivity: now - elevenHours, now: now))
    }

    @Test func aChatHistoryCannotContinueStays() {
        #expect(!AgentChatRetirement.isRetired(agentID: "codex", cliSessionID: "abc", lastActivity: now - thirteenHours, now: now))
        #expect(!AgentChatRetirement.isRetired(agentID: "claude", cliSessionID: nil, lastActivity: now - thirteenHours, now: now))
    }
}
