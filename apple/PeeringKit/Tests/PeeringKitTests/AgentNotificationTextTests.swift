import RemoteCore
import Testing

@testable import PeeringKit

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

@Suite struct AgentTurnDigestTests {
    @Test func aFinishedTurnSaysWhatItChangedAndHowLongItTook() {
        let text = AgentNotificationText.finished(
            agentName: "Claude Code", ok: true, stopped: false, lastReply: "Fixed it.", editedFiles: 3, duration: 134
        )
        #expect(text.body == "Fixed it.\n3 files changed · 2m 14s")
    }

    @Test func oneFileIsNotPlural() {
        #expect(AgentTurnDigest.detail(editedFiles: 1, duration: nil) == "1 file changed")
    }

    @Test func aQuickTurnThatChangedNothingAddsNoLine() {
        #expect(AgentTurnDigest.detail(editedFiles: 0, duration: 3) == nil)
        #expect(AgentNotificationText.finished(agentName: "A", ok: true, stopped: false, lastReply: "Hi", duration: 3).body == "Hi")
    }

    @Test func aReadIsNotAnEdit() {
        #expect(!AgentTurnDigest.edits(AgentToolCall(id: "1", name: "Read", title: "Read", filePath: "/a")))
        #expect(AgentTurnDigest.edits(AgentToolCall(id: "2", name: "Write", title: "Write", filePath: "/a")))
        #expect(AgentTurnDigest.edits(AgentToolCall(id: "3", name: "file_change", title: "Edit", filePath: "/a", diff: "+x")))
    }
}
