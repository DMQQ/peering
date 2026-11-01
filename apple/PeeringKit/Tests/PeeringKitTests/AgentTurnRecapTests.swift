import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

@Suite("Agent turn recap")
struct AgentTurnRecapTests {
    private func edit(_ id: String, _ path: String) -> AgentToolCall {
        AgentToolCall(id: id, name: "Edit", title: "Edit", filePath: path)
    }

    private func shell(_ id: String, _ command: String) -> AgentToolCall {
        AgentToolCall(id: id, name: "Bash", title: "Bash", detail: command)
    }

    @Test("edits, a passing test run and an unpushed commit make one line")
    func fullLine() {
        var recap = AgentTurnRecap()
        for index in 1 ... 4 { recap.started(edit("e\(index)", "/p/f\(index).swift")) }
        recap.started(shell("t", "cd PeeringKit && swift test"))
        recap.finished(callID: "t", ok: true)
        recap.started(shell("c", "git commit -m wip"))
        recap.finished(callID: "c", ok: true)
        #expect(recap.line() == "Changed 4 files, tests passed, waiting to push")
    }

    @Test("a file edited twice counts once")
    func distinctFiles() {
        var recap = AgentTurnRecap()
        recap.started(edit("a", "/p/x.swift"))
        recap.started(edit("b", "/p/x.swift"))
        #expect(recap.line() == "Changed 1 file")
    }

    @Test("a failing run stays the news after a later run passes")
    func failureSticks() {
        var recap = AgentTurnRecap()
        recap.started(shell("1", "npm test"))
        recap.finished(callID: "1", ok: false)
        recap.started(shell("2", "npm test"))
        recap.finished(callID: "2", ok: true)
        #expect(recap.line() == "Tests failed")
    }

    @Test("a commit that was pushed is not waiting")
    func pushed() {
        var recap = AgentTurnRecap()
        recap.started(shell("c", "git commit -am fix"))
        recap.finished(callID: "c", ok: true)
        recap.started(shell("p", "git push origin main"))
        recap.finished(callID: "p", ok: true)
        #expect(recap.line() == nil)
    }

    @Test("a failed commit, an unrelated command and a test never finished say nothing")
    func nothingToSay() {
        var recap = AgentTurnRecap()
        recap.started(shell("c", "git commit -m x"))
        recap.finished(callID: "c", ok: false)
        recap.started(shell("l", "ls -la"))
        recap.finished(callID: "l", ok: true)
        recap.started(shell("t", "pytest"))
        #expect(recap.line() == nil)
    }

    @Test("the finished notification uses the recap in place of the file count and keeps the duration")
    func notificationBody() {
        let text = AgentNotificationText.finished(
            agentName: "Claude", ok: true, stopped: false, lastReply: "Done.", editedFiles: 2, duration: 30,
            recap: "Changed 2 files, tests passed"
        )
        #expect(text.body == "Done.\nChanged 2 files, tests passed · 30.0s")
    }
}
