import Foundation
import Testing

@testable import PeeringKit
import RemoteCore

/// Fixture lines follow the read and write examples in https://cursor.com/docs/cli/reference/output-format;
/// the shell call is not in the docs and follows the same keyed shape.
struct AgentCursorStreamTests {
    private let system = #"{"type":"system","subtype":"init","apiKeySource":"login","cwd":"/tmp/c","session_id":"c-1","model":"Claude 4 Sonnet","permissionMode":"default"}"#
    private let user = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"make a file"}]},"session_id":"c-1"}"#
    private let assistant = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll create it."}]},"session_id":"c-1"}"#
    private let writeStarted = #"{"type":"tool_call","subtype":"started","call_id":"w1","tool_call":{"writeToolCall":{"args":{"path":"/tmp/c/a.txt","fileText":"hi","toolCallId":"w1"}}},"session_id":"c-1"}"#
    private let writeDone = #"{"type":"tool_call","subtype":"completed","call_id":"w1","tool_call":{"writeToolCall":{"args":{"path":"/tmp/c/a.txt"},"result":{"success":{"path":"/tmp/c/a.txt","linesCreated":1,"fileSize":2}}}},"session_id":"c-1"}"#
    private let shellFailed = #"{"type":"tool_call","subtype":"completed","call_id":"s1","tool_call":{"shellToolCall":{"args":{"command":"rm -rf x"},"result":{"rejected":{"command":"rm -rf x","reason":"Not allowed"}}}},"session_id":"c-1"}"#
    private let result = #"{"type":"result","subtype":"success","duration_ms":1234,"duration_api_ms":1200,"is_error":false,"result":"I'll create it.","session_id":"c-1"}"#

    @Test func writeTurnEmitsSessionToolTextAndFinish() {
        var stream = AgentCursorStream(directory: "/tmp/c")
        let events = [system, user, assistant, writeStarted, writeDone, result].flatMap { stream.receive(line: $0) }

        #expect(stream.cliSessionID == "c-1")
        #expect(events[0] == .sessionReady(agentID: "cursor-agent", cliSessionID: "c-1", model: "Claude 4 Sonnet", directory: "/tmp/c"))
        #expect(events[1] == .turnStarted)
        #expect(events[2] == .textFinal(text: "I'll create it."))
        #expect(events[3] == .toolStarted(call: AgentToolCall(id: "w1", name: "write", title: "Write", detail: "/tmp/c/a.txt", filePath: "/tmp/c/a.txt")))
        #expect(events[4] == .toolFinished(callID: "w1", ok: true, output: nil, truncated: false))
        guard case .turnFinished(let summary) = events[5] else {
            Issue.record("expected turnFinished, got \(events[5])")
            return
        }
        #expect(summary.ok)
        #expect(summary.duration == 1.234)
    }

    @Test func toolWithoutSuccessIsAFailedCall() {
        var stream = AgentCursorStream(directory: "/tmp/c", cliSessionID: "c-1")
        let events = stream.receive(line: shellFailed)
        #expect(events.last == .toolFinished(callID: "s1", ok: false, output: nil, truncated: false))
    }

    @Test func errorResultIsAFailedTurn() {
        var stream = AgentCursorStream(directory: "/tmp/c", cliSessionID: "c-1")
        let line = #"{"type":"result","subtype":"error","is_error":true,"result":"Out of requests.","session_id":"c-1"}"#
        let events = stream.receive(line: line)
        #expect(events.contains(.notice(text: "Out of requests.")))
        guard case .turnFinished(let summary) = events.last else {
            Issue.record("expected turnFinished last")
            return
        }
        #expect(!summary.ok)
    }
}
