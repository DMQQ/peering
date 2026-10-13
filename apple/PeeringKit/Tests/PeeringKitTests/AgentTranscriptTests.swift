import XCTest

@testable import PeeringKit
import RemoteCore

final class AgentTranscriptTests: XCTestCase {
    private func event(_ index: UInt64, _ payload: AgentStreamEvent.Payload) -> AgentStreamEvent {
        AgentStreamEvent(index: index, payload: payload)
    }

    private func reply(_ transcript: AgentTranscript) -> String? {
        for item in transcript.items.reversed() {
            if case .reply(_, let text) = item { return text }
        }
        return nil
    }

    private func tool(_ transcript: AgentTranscript) -> AgentToolItem? {
        for item in transcript.items.reversed() {
            if case .tool(_, let tool) = item { return tool }
        }
        return nil
    }

    private func call(id: String = "t1", name: String = "Bash", detail: String? = "npm test") -> AgentToolCall {
        AgentToolCall(id: id, name: name, title: name, detail: detail)
    }

    // MARK: - Streaming text

    func testDeltasGrowOneReplyAndTheFinalReplacesIt() {
        var transcript = AgentTranscript()
        transcript.apply(event(1, .userPrompt(text: "Run the tests")))
        transcript.apply(event(2, .turnStarted))
        transcript.apply(event(3, .textDelta(text: "Run")))
        transcript.apply(event(4, .textDelta(text: "ning ")))
        transcript.apply(event(5, .textDelta(text: "now.")))
        XCTAssertEqual(reply(transcript), "Running now.")
        XCTAssertEqual(transcript.state, .working)

        // The authoritative block, even with a delta lost: replacement, not appending.
        transcript.apply(event(6, .textFinal(text: "Running the tests now.")))
        XCTAssertEqual(reply(transcript), "Running the tests now.")
        XCTAssertEqual(transcript.items.filter { if case .reply = $0 { return true }; return false }.count, 1)
    }

    func testTextAroundAToolIsTwoReplies() {
        var transcript = AgentTranscript()
        transcript.apply(event(1, .textFinal(text: "Let me check.")))
        transcript.apply(event(2, .toolStarted(call: call())))
        transcript.apply(event(3, .textDelta(text: "It passed.")))
        let texts: [String] = transcript.items.compactMap {
            if case .reply(_, let text) = $0 { return text }
            return nil
        }
        XCTAssertEqual(texts, ["Let me check.", "It passed."])
    }

    // MARK: - Replay

    func testDuplicateAndLateEventsAreIgnored() {
        var transcript = AgentTranscript()
        transcript.apply(event(7, .textFinal(text: "seven")))
        transcript.apply(event(7, .textFinal(text: "seven again")))
        transcript.apply(event(3, .textFinal(text: "three")))
        XCTAssertEqual(transcript.items.count, 1)
        XCTAssertEqual(reply(transcript), "seven")
        XCTAssertEqual(transcript.lastIndex, 7)
    }

    func testRebuildFromReplayWithALiveEventAlreadyApplied() {
        let live = [event(4, .textDelta(text: "live"))]

        var rebuilt = AgentTranscript()
        rebuilt.apply(event(1, .userPrompt(text: "hi")))
        rebuilt.apply(event(2, .turnStarted))
        rebuilt.apply(event(3, .textDelta(text: "Hel")))
        // The replay of 1...4 arrives after 4 has already been delivered live.
        rebuilt.apply([event(1, .userPrompt(text: "hi")), event(2, .turnStarted),
                       event(3, .textDelta(text: "Hel")), event(4, .textDelta(text: "lo"))])

        var clean = AgentTranscript()
        clean.apply([event(1, .userPrompt(text: "hi")), event(2, .turnStarted),
                     event(3, .textDelta(text: "Hel")), event(4, .textDelta(text: "lo"))])

        XCTAssertEqual(reply(rebuilt), reply(clean))
        XCTAssertEqual(rebuilt.lastIndex, clean.lastIndex)
        XCTAssertEqual(rebuilt.items.count, clean.items.count)
        XCTAssertFalse(live.isEmpty)
    }

    func testResetForAFullRebuild() {
        var transcript = AgentTranscript()
        transcript.apply(event(1, .userPrompt(text: "old")))
        transcript.apply(event(2, .turnFinished(summary: AgentTurnSummary(ok: true))))
        transcript.reset()
        XCTAssertTrue(transcript.isEmpty)
        XCTAssertEqual(transcript.lastIndex, 0)
        XCTAssertEqual(transcript.state, .idle)
    }

    // MARK: - Tools and approvals

    func testToolLifecycle() {
        var transcript = AgentTranscript()
        transcript.apply(event(1, .toolStarted(call: call())))
        XCTAssertEqual(tool(transcript)?.state, .running)

        transcript.apply(event(2, .toolFinished(callID: "t1", ok: true, output: "24 tests passed", truncated: false)))
        XCTAssertEqual(tool(transcript)?.state, .ok)
        XCTAssertEqual(tool(transcript)?.output, "24 tests passed")
    }

    func testOrphanToolResultIsIgnored() {
        var transcript = AgentTranscript()
        transcript.apply(event(1, .toolFinished(callID: "gone", ok: true, output: "x", truncated: false)))
        XCTAssertTrue(transcript.isEmpty)
    }

    func testApprovalAttachesToItsCard() {
        var transcript = AgentTranscript()
        transcript.apply(event(1, .toolStarted(call: call())))
        transcript.apply(event(2, .approvalRequested(approvalID: "req_1", call: call(), reason: "Run the tests")))

        XCTAssertEqual(transcript.state, .awaitingApproval)
        XCTAssertEqual(transcript.pendingApprovals.map(\.id), ["req_1"])
        XCTAssertEqual(tool(transcript)?.state, .awaitingApproval(id: "req_1"))
        // One card, not an ask beside a card: the approval is about the call already drawn.
        XCTAssertEqual(transcript.items.filter { if case .tool = $0 { return true }; return false }.count, 1)

        transcript.apply(event(3, .approvalResolved(approvalID: "req_1", decision: .deny)))
        XCTAssertTrue(transcript.pendingApprovals.isEmpty)
        XCTAssertEqual(tool(transcript)?.state, .denied)
        XCTAssertEqual(transcript.state, .working)
    }

    func testApprovalWithoutACardMakesOne() {
        var transcript = AgentTranscript()
        transcript.apply(event(1, .approvalRequested(approvalID: "req_2", call: call(id: "t9"), reason: nil)))
        XCTAssertEqual(tool(transcript)?.state, .awaitingApproval(id: "req_2"))
    }

    func testTurnEndClearsPendingApprovalsAndAddsSummary() {
        var transcript = AgentTranscript()
        transcript.apply(event(1, .approvalRequested(approvalID: "req_3", call: call(), reason: nil)))
        transcript.apply(event(2, .turnFinished(summary: AgentTurnSummary(ok: false, stopped: true))))
        XCTAssertTrue(transcript.pendingApprovals.isEmpty)
        XCTAssertEqual(transcript.state, .idle)
        guard case .summary(_, let summary) = transcript.items.last else {
            return XCTFail("expected a summary row, got \(String(describing: transcript.items.last))")
        }
        XCTAssertTrue(summary.stopped)
    }

    func testFailureAndExit() {
        var transcript = AgentTranscript()
        transcript.apply(event(1, .failure(message: "claude exited with status 1")))
        XCTAssertEqual(transcript.state, .failed)

        var second = AgentTranscript()
        second.apply(event(1, .sessionExited(status: 0)))
        XCTAssertEqual(second.state, .exited)
    }

    // MARK: - Trimming

    func testTrimmingKeepsWholeTurns() {
        var transcript = AgentTranscript()
        let chunk = String(repeating: "x", count: 64 * 1024)
        var index: UInt64 = 0
        for turn in 1...8 {
            index += 1
            transcript.apply(event(index, .userPrompt(text: "turn \(turn)")))
            index += 1
            transcript.apply(event(index, .textFinal(text: chunk)))
            index += 1
            transcript.apply(event(index, .turnFinished(summary: AgentTurnSummary(ok: true))))
        }

        XCTAssertTrue(transcript.truncatedAtFront)
        guard let first = transcript.items.first else {
            return XCTFail("a trimmed transcript is not empty")
        }
        guard case .user(_, let firstKept) = first else {
            return XCTFail("a trimmed transcript should begin at a turn boundary, begins at \(first)")
        }
        XCTAssertTrue(firstKept.hasPrefix("turn "), firstKept)
        XCTAssertFalse(firstKept.hasPrefix("turn 1"), "the oldest whole turn should be the one dropped")
        XCTAssertEqual(reply(transcript), chunk)
    }
}
