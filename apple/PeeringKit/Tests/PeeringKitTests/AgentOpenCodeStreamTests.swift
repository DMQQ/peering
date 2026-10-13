import XCTest

@testable import MacCastKit
import RemoteCore

/// Fixtures are lines captured from a real opencode 1.18.34 process, trimmed to the fields the parser reads. The permission case is real: without `--auto` a call outside the folder is rejected.
final class AgentOpenCodeStreamTests: XCTestCase {
    private func payloads(_ lines: [String]) -> [AgentStreamEvent.Payload] {
        var stream = AgentOpenCodeStream(directory: "/tmp/oc")
        return lines.flatMap { stream.receive(line: $0) }
    }

    private let stepStart = #"{"type":"step_start","sessionID":"ses_a","part":{"type":"step-start"}}"#
    private let stepToolCalls = #"{"type":"step_finish","sessionID":"ses_a","part":{"type":"step-finish","reason":"tool-calls","tokens":{"total":16812,"input":16691,"output":88,"reasoning":33}}}"#
    private let stepStop = #"{"type":"step_finish","sessionID":"ses_a","part":{"type":"step-finish","reason":"stop","tokens":{"total":16878,"input":89,"output":17,"reasoning":4}}}"#
    private let text = #"{"type":"text","sessionID":"ses_a","part":{"type":"text","text":"hello.txt created."}}"#

    private let bash = #"{"type":"tool_use","sessionID":"ses_a","part":{"type":"tool","tool":"bash","callID":"call_1","state":{"status":"completed","input":{"command":"ls"},"output":"hello.txt\n","metadata":{"exit":0}}}}"#
    private let write = #"{"type":"tool_use","sessionID":"ses_a","part":{"type":"tool","tool":"write","callID":"call_2","state":{"status":"completed","input":{"filePath":"/tmp/oc/hello.txt","content":"hi"},"output":"Wrote file successfully."}}}"#
    private let edit = #"{"type":"tool_use","sessionID":"ses_a","part":{"type":"tool","tool":"edit","callID":"call_3","state":{"status":"completed","input":{"filePath":"/tmp/oc/hello.txt","oldString":"hi","newString":"hello world"},"output":"Edit applied successfully.","metadata":{"diff":"--- a\n+++ b\n@@ -1,1 +1,1 @@\n-hi\n+hello world\n"}}}}"#
    private let rejected = #"{"type":"tool_use","sessionID":"ses_a","part":{"type":"tool","tool":"bash","callID":"call_4","state":{"status":"error","input":{"command":"touch /tmp/x"},"error":"The user rejected permission to use this specific tool call."}}}"#
    private let failure = #"{"type":"error","sessionID":"ses_a","error":{"name":"UnknownError","data":{"message":"Unexpected server error. Check server logs for details.","ref":"err_3dccbb29"}}}"#

    func testTextTurn() {
        var stream = AgentOpenCodeStream(directory: "/tmp/oc")
        let payloads = [stepStart, text, stepStop].flatMap { stream.receive(line: $0) }

        XCTAssertEqual(stream.cliSessionID, "ses_a")
        XCTAssertEqual(
            payloads[0],
            .sessionReady(agentID: "opencode", cliSessionID: "ses_a", model: nil, directory: "/tmp/oc")
        )
        XCTAssertEqual(payloads[1], .turnStarted)
        XCTAssertEqual(payloads[2], .textFinal(text: "hello.txt created."))
        guard case .turnFinished(let summary) = payloads[3] else {
            return XCTFail("expected turnFinished last, got \(payloads[3])")
        }
        XCTAssertTrue(summary.ok)
        XCTAssertEqual(summary.inputTokens, 89)
        XCTAssertEqual(summary.outputTokens, 17)
    }

    func testAToolStepIsNotTheEndOfTheTurn() {
        let payloads = payloads([stepStart, bash, stepToolCalls, stepStart, text, stepStop])

        let started = payloads.filter { $0 == .turnStarted }
        XCTAssertEqual(started.count, 1)
        let finished = payloads.filter { if case .turnFinished = $0 { return true } else { return false } }
        XCTAssertEqual(finished.count, 1)
        guard case .turnFinished(let summary) = finished[0] else { return XCTFail() }
        XCTAssertEqual(summary.inputTokens, 16691 + 89)
        XCTAssertEqual(summary.outputTokens, 88 + 17)
    }

    func testAToolArrivesFinishedAndIsOpenedAndClosedTogether() {
        let payloads = payloads([bash])

        guard case .toolStarted(let call) = payloads[2] else {
            return XCTFail("expected toolStarted, got \(payloads)")
        }
        XCTAssertEqual(call.id, "call_1")
        XCTAssertEqual(call.title, "Command")
        XCTAssertEqual(call.detail, "ls")
        XCTAssertEqual(
            payloads[3],
            .toolFinished(callID: "call_1", ok: true, output: "hello.txt\n", truncated: false)
        )
    }

    func testWriteNamesTheFileAndSaysNothingUnderIt() {
        let payloads = payloads([write])

        guard case .toolStarted(let call) = payloads[2] else { return XCTFail() }
        XCTAssertEqual(call.title, "Write")
        XCTAssertEqual(call.filePath, "/tmp/oc/hello.txt")
        XCTAssertEqual(
            payloads[3],
            .toolFinished(callID: "call_2", ok: true, output: nil, truncated: false)
        )
    }

    func testEditCarriesTheCLIsOwnDiff() {
        let payloads = payloads([edit])

        guard case .toolStarted(let call) = payloads[2] else { return XCTFail() }
        XCTAssertEqual(call.title, "Edit")
        XCTAssertEqual(call.diff, "--- a\n+++ b\n@@ -1,1 +1,1 @@\n-hi\n+hello world\n")
    }

    func testARejectedCallIsAFailedToolWithTheCLIsSentence() {
        let payloads = payloads([rejected])

        XCTAssertEqual(
            payloads[3],
            .toolFinished(
                callID: "call_4",
                ok: false,
                output: "The user rejected permission to use this specific tool call.",
                truncated: false
            )
        )
    }

    func testAnErrorIsANoticeAndEndsTheTurn() {
        let payloads = payloads([failure])

        XCTAssertTrue(payloads.contains(.notice(text: "Unexpected server error. Check server logs for details.")))
        guard case .turnFinished(let summary) = payloads.last else {
            return XCTFail("expected turnFinished last, got \(payloads)")
        }
        XCTAssertFalse(summary.ok)
    }

    func testASecondTurnOnTheSameSessionDoesNotAnnounceItAgain() {
        var stream = AgentOpenCodeStream(directory: "/tmp/oc")
        _ = [stepStart, text, stepStop].flatMap { stream.receive(line: $0) }
        let second = [stepStart, text, stepStop].flatMap { stream.receive(line: $0) }

        XCTAssertEqual(second.first, .turnStarted)
        XCTAssertFalse(second.contains { if case .sessionReady = $0 { return true } else { return false } })
    }

    func testAnUnknownLineIsAnnouncedOnce() {
        var stream = AgentOpenCodeStream(directory: "/tmp/oc")
        let line = #"{"type":"something_new","sessionID":"ses_a"}"#
        let first = stream.receive(line: line)
        let again = stream.receive(line: line)

        XCTAssertTrue(first.contains { if case .notice = $0 { return true } else { return false } })
        XCTAssertTrue(again.isEmpty)
    }
}
