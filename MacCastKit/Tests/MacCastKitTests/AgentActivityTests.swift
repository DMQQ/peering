import XCTest

@testable import MacCastKit
import RemoteCore

final class AgentActivityTests: XCTestCase {
    func testClaudeTodoWriteBecomesAPlan() {
        var stream = AgentClaudeStream()
        let line = #"{"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"TodoWrite","input":{"todos":[{"content":"Read the code","status":"completed","activeForm":"Reading"},{"content":"Write the fix","status":"in_progress","activeForm":"Writing"},{"content":"Run tests","status":"pending","activeForm":"Running"}]}}]},"parent_tool_use_id":null,"session_id":"s","uuid":"u"}"#
        var transcript = AgentTranscript()
        for payload in stream.receive(line: line) { transcript.apply(payload) }
        let plan = transcript.planProgress
        XCTAssertEqual(plan?.total, 3)
        XCTAssertEqual(plan?.completed, 1)
        XCTAssertEqual(plan?.current?.text, "Write the fix")
        XCTAssertEqual(plan?.currentNumber, 2)
    }

    func testActivityNamesTheRunningTool() {
        var transcript = AgentTranscript()
        transcript.apply(.turnStarted)
        transcript.apply(.toolStarted(call: AgentToolCall(id: "a", name: "Bash", title: "Bash", detail: "swift test --filter Foo\nmore")))
        XCTAssertEqual(transcript.activity, "Running swift test --filter Foo")
    }

    func testIdleHasNoActivity() {
        XCTAssertNil(AgentTranscript().activity)
    }
}
