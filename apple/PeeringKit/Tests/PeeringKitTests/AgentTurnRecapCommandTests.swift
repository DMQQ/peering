import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

@Suite("Agent turn recap commands")
struct AgentTurnRecapCommandTests {
    private func run(_ command: String, ok: Bool = true) -> AgentTurnRecap {
        var recap = AgentTurnRecap()
        recap.started(AgentToolCall(id: "c", name: "Bash", title: "Bash", detail: command))
        recap.finished(callID: "c", ok: ok)
        return recap
    }

    @Test("a commit and push in one command records both")
    func commitAndPush() {
        let recap = run("git add . && git commit -m wip && git push")
        #expect(recap.committed)
        #expect(recap.pushed)
    }

    @Test("a commit followed by a test run records both")
    func commitThenTest() {
        let recap = run("git commit -m wip; swift test")
        #expect(recap.committed)
        #expect(recap.tests == .passed)
    }

    @Test("a program name inside another word is not a test run")
    func wordBoundary() {
        #expect(run("cat jest.config.js").tests == nil)
        #expect(run("grep 'swift test' notes.md").tests == nil)
        #expect(run("echo git push").pushed == false)
    }

    @Test("git options before the verb still name it")
    func gitOptions() {
        #expect(run("git -C repo commit -m x").committed)
    }

    @Test("a test run after a launcher or environment variable counts")
    func launchers() {
        #expect(run("CI=1 npx jest").tests == .passed)
    }

    @Test("a pipe separates commands")
    func pipe() {
        #expect(run("swift test | tail -5", ok: false).tests == .failed)
    }
}

@Suite("Agent finished notification recap")
struct AgentFinishedRecapTests {
    @Test("the recap keeps the turn's duration")
    func recapWithDuration() {
        let text = AgentNotificationText.finished(
            agentName: "Claude", ok: true, stopped: false, lastReply: "Done",
            duration: 75, recap: "Changed 2 files"
        )
        #expect(text.body.hasPrefix("Done\nChanged 2 files · "))
        #expect(text.body != "Done\nChanged 2 files")
    }

    @Test("a short turn's recap has no duration")
    func shortTurn() {
        let text = AgentNotificationText.finished(
            agentName: "Claude", ok: true, stopped: false, lastReply: "Done",
            duration: 2, recap: "Changed 2 files"
        )
        #expect(text.body == "Done\nChanged 2 files")
    }
}
