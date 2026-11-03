import Foundation
import Testing

@testable import PeeringKit
import RemoteCore

/// Fixture lines follow the events gemini-cli 0.62 writes in its non-interactive stream-json mode.
struct AgentGeminiStreamTests {
    private let initLine = #"{"type":"init","timestamp":"2026-11-03T10:00:00Z","session_id":"g-1","model":"gemini-2.5-pro"}"#
    private let userLine = #"{"type":"message","role":"user","content":"list files"}"#
    private let deltaOne = #"{"type":"message","role":"assistant","content":"Here ","delta":true}"#
    private let deltaTwo = #"{"type":"message","role":"assistant","content":"they are.","delta":true}"#
    private let toolUse = #"{"type":"tool_use","tool_name":"run_shell_command","tool_id":"t1","parameters":{"command":"ls"}}"#
    private let toolOK = #"{"type":"tool_result","tool_id":"t1","status":"success","output":"a.txt"}"#
    private let toolDenied = #"{"type":"tool_result","tool_id":"t1","status":"error","output":"","error":{"type":"TOOL_EXECUTION_ERROR","message":"Tool execution denied by policy."}}"#
    private let resultOK = #"{"type":"result","status":"success","stats":{"total_tokens":120,"input_tokens":100,"output_tokens":20,"cached":40,"duration_ms":1500,"tool_calls":1}}"#
    private let resultFailed = #"{"type":"result","status":"error","error":{"type":"FatalAuthenticationError","message":"Not signed in."},"stats":{"total_tokens":0,"input_tokens":0,"output_tokens":0,"cached":0,"duration_ms":0}}"#

    @Test func toolTurnEmitsSessionToolTextAndFinish() {
        var stream = AgentGeminiStream(directory: "/tmp/g")
        let events = [initLine, userLine, toolUse, toolOK, deltaOne, deltaTwo, resultOK]
            .flatMap { stream.receive(line: $0) }

        #expect(stream.cliSessionID == "g-1")
        #expect(events[0] == .sessionReady(agentID: "gemini", cliSessionID: "g-1", model: "gemini-2.5-pro", directory: "/tmp/g"))
        #expect(events[1] == .turnStarted)
        #expect(events[2] == .toolStarted(call: AgentToolCall(id: "t1", name: "run_shell_command", title: "Command", detail: "ls")))
        #expect(events[3] == .toolFinished(callID: "t1", ok: true, output: "a.txt", truncated: false))
        #expect(events[4] == .textFinal(text: "Here they are."))
        guard case .turnFinished(let summary) = events[5] else {
            Issue.record("expected turnFinished, got \(events[5])")
            return
        }
        #expect(summary.ok)
        #expect(summary.inputTokens == 100)
        #expect(summary.outputTokens == 20)
        #expect(stream.usage.cachedTokens == 40)
        #expect(stream.usage.inputTokens == 60)
    }

    @Test func deniedToolCarriesTheReason() {
        var stream = AgentGeminiStream(directory: "/tmp/g")
        let events = [toolUse, toolDenied].flatMap { stream.receive(line: $0) }
        #expect(events.last == .toolFinished(callID: "t1", ok: false, output: "Tool execution denied by policy.", truncated: false))
    }

    @Test func failedResultReportsTheErrorAndAFailedTurn() {
        var stream = AgentGeminiStream(directory: "/tmp/g")
        let events = stream.receive(line: resultFailed)
        #expect(events.contains(.notice(text: "Not signed in.")))
        guard case .turnFinished(let summary) = events.last else {
            Issue.record("expected turnFinished last")
            return
        }
        #expect(!summary.ok)
    }

    @Test func resumedSessionWithTheSameIDIsNotAnnouncedAgain() {
        var stream = AgentGeminiStream(directory: "/tmp/g", cliSessionID: "g-1")
        #expect(stream.receive(line: initLine).isEmpty)
    }

    @Test func unreadableLineBecomesANotice() {
        var stream = AgentGeminiStream(directory: "/tmp/g")
        #expect(stream.receive(line: "Loaded cached credentials.") == [.notice(text: "A line of Gemini CLI's output could not be read.")])
    }
}
