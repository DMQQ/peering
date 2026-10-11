import Testing

@testable import MacCastKit
@testable import RemoteCore

@Suite struct AgentBackgroundSubagentTests {
    private let task = AgentToolCall(id: "t1", name: "Task", title: "Task", detail: "review")

    private func launched() -> AgentTranscript {
        var transcript = AgentTranscript()
        transcript.apply(.turnStarted)
        transcript.apply(.toolStarted(call: task))
        // A background launch finishes at once, with nothing worth showing.
        transcript.apply(.toolFinished(callID: "t1", ok: true, output: nil, truncated: false))
        transcript.apply(.child(parentCallID: "t1", event: .textFinal(text: "Reading the diff")))
        return transcript
    }

    @Test func theBackgroundAgentWorksUntilItIsToldItIsDone() {
        let transcript = launched()
        #expect(transcript.runningSubagents.count == 1)
    }

    @Test func itsCompletionNoticeEndsTheWork() {
        var transcript = launched()
        transcript.apply(.toolFinished(callID: "t1", ok: true, output: nil, truncated: false))
        #expect(transcript.runningSubagents.isEmpty)
    }

    @Test func aSecondFinishKeepsTheOutputTheFirstGave() {
        var transcript = AgentTranscript()
        transcript.apply(.toolStarted(call: task))
        transcript.apply(.toolFinished(callID: "t1", ok: true, output: "result", truncated: false))
        transcript.apply(.toolFinished(callID: "t1", ok: true, output: nil, truncated: false))
        guard case .tool(_, let item) = transcript.items[0] else {
            Issue.record("expected a tool")
            return
        }
        #expect(item.output == "result")
    }

    @Test func theStreamTurnsATaskNoticeIntoAFinish() {
        var stream = AgentClaudeStream()
        let done = stream.receive(line: #"{"type":"system","subtype":"task_notification","tool_use_id":"t1","status":"completed"}"#)
        #expect(done == [.toolFinished(callID: "t1", ok: true, output: nil, truncated: false)])
        let killed = stream.receive(line: #"{"type":"system","subtype":"task_notification","tool_use_id":"t1","status":"killed"}"#)
        #expect(killed == [.toolFinished(callID: "t1", ok: false, output: nil, truncated: false)])
    }

    @Test func aNoticeWithoutACallIsIgnored() {
        var stream = AgentClaudeStream()
        #expect(stream.receive(line: #"{"type":"system","subtype":"task_notification","status":"completed"}"#).isEmpty)
    }
}
