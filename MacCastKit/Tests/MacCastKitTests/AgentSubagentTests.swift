import Foundation
import Testing

@testable import MacCastKit
import RemoteCore

struct AgentSubagentTests {
    private let childText = #"{"type":"assistant","message":{"content":[{"type":"text","text":"found it"}]},"parent_tool_use_id":"toolu_task","session_id":"s"}"#
    private let childTool = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_read","name":"Read","input":{"file_path":"/a.swift"}}]},"parent_tool_use_id":"toolu_task","session_id":"s"}"#
    private let childResult = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_read","content":"ok"}]},"parent_tool_use_id":"toolu_task","session_id":"s"}"#

    private func transcript(_ lines: [String]) -> AgentTranscript {
        var stream = AgentClaudeStream()
        var transcript = AgentTranscript()
        transcript.apply(.toolStarted(call: AgentToolCall(id: "toolu_task", name: "Task", title: "Task", detail: "Explore")))
        for line in lines {
            for payload in stream.receive(line: line) { transcript.apply(payload) }
        }
        return transcript
    }

    @Test func aSubagentLineIsFiledUnderItsTaskCall() {
        var stream = AgentClaudeStream()
        #expect(stream.receive(line: childText) == [.child(parentCallID: "toolu_task", event: .textFinal(text: "found it"))])
    }

    @Test func aSubagentDoesNotAppearInTheMainConversation() {
        let result = transcript([childText, childTool])
        #expect(result.items.count == 1)
        #expect(result.children["toolu_task"]?.items.count == 2)
    }

    @Test func aChildToolFinishesInsideTheChild() {
        let result = transcript([childTool, childResult])
        guard case .tool(_, let tool)? = result.children["toolu_task"]?.items.first else {
            Issue.record("the child has no tool")
            return
        }
        #expect(tool.state == .ok)
    }

    @Test func finishingTheTaskCallEndsTheSubagent() {
        var result = transcript([childText])
        #expect(result.children["toolu_task"]?.state == .working)
        result.apply(.toolFinished(callID: "toolu_task", ok: true, output: "done", truncated: false))
        #expect(result.children["toolu_task"]?.state == .idle)
    }

    @Test func subagentsListInTheOrderTheyWereSpawned() {
        let result = transcript([childText])
        #expect(result.subagents.map(\.call.id) == ["toolu_task"])
    }

    @Test func aChildEventSurvivesTheWire() throws {
        let payload = AgentStreamEvent.Payload.child(parentCallID: "t", event: .textFinal(text: "hi"))
        let decoded = try JSONDecoder().decode(AgentStreamEvent.Payload.self, from: JSONEncoder().encode(payload))
        #expect(decoded == payload)
    }
}

extension AgentSubagentTests {
    @Test func onlyAWorkingSubagentIsRunning() {
        var result = transcript([childText])
        #expect(result.runningSubagents.map(\.call.id) == ["toolu_task"])
        result.apply(.toolFinished(callID: "toolu_task", ok: true, output: nil, truncated: false))
        #expect(result.runningSubagents.isEmpty)
    }

    @Test func aSubagentSaysWhatItIsDoing() {
        let result = transcript([childTool])
        #expect(result.runningSubagents.first?.transcript.activity == "Reading a.swift")
    }

    @Test func aSubagentRecordsWhenItStarted() {
        #expect(transcript([childText]).children["toolu_task"]?.startedAt != nil)
    }
}
