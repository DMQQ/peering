@testable import PeeringKit
import Testing

@Suite struct AgentClaudeContextWindowTests {
    @Test func theChatsOwnModelWinsOverAHelper() {
        let usage: [String: Any] = [
            "claude-haiku": ["contextWindow": 100_000],
            "claude-opus": ["contextWindow": 1_000_000],
        ]
        #expect(AgentClaudeStream.contextWindow(in: usage, model: "claude-haiku") == 100_000)
    }

    @Test func anEntryWithoutAWindowDoesNotHideTheOther() {
        let usage: [String: Any] = ["helper": ["costUSD": 0.01], "claude-opus": ["contextWindow": 200_000]]
        #expect(AgentClaudeStream.contextWindow(in: usage, model: "unlisted") == 200_000)
    }
}
