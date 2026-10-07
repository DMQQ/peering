import Testing

@testable import MacCastKit

@Suite struct AgentNotificationTextTests {
    @Test func anApprovalLeadsWithItsCommandThenItsReason() {
        #expect(AgentNotificationText.approval(agentName: "Codex", reason: "why", detail: "ls").body == "ls\n\nwhy")
        #expect(AgentNotificationText.approval(agentName: "Codex", reason: nil, detail: "ls").body == "ls")
        #expect(AgentNotificationText.approval(agentName: "Codex", reason: nil, detail: nil).body == "Needs your approval.")
        #expect(AgentNotificationText.approval(agentName: "Codex", reason: nil, detail: nil).title == "Codex asks")
    }

    @Test func aFinishedTurnShowsTheFirstLineOfTheReply() {
        let text = AgentNotificationText.finished(agentName: "Claude Code", ok: true, stopped: false, lastReply: "Done.\nMore below.")
        #expect(text.title == "Claude Code finished")
        #expect(text.body == "Done.")
    }

    @Test func aLongReplyIsCutAtOneHundredFortyCharacters() {
        let text = AgentNotificationText.finished(agentName: "A", ok: true, stopped: false, lastReply: String(repeating: "x", count: 300))
        #expect(text.body.count == 140)
    }

    @Test func withoutAReplyTheOutcomeSpeaksForItself() {
        #expect(AgentNotificationText.finished(agentName: "A", ok: false, stopped: true, lastReply: nil).body == "The turn was stopped.")
        #expect(AgentNotificationText.finished(agentName: "A", ok: false, stopped: false, lastReply: "").title == "A failed")
    }
}
