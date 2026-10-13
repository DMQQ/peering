import XCTest

@testable import PeeringKit
import RemoteCore

/// Fixtures are lines captured from a real codex-cli 0.157.1 process (`codex exec --json`), trimmed to the fields the parser reads. The failed turn is real: that account's model is refused by the API.
final class AgentCodexStreamTests: XCTestCase {
    private func payloads(_ lines: [String], directory: String = "/tmp/agentchat-capture") -> [AgentStreamEvent.Payload] {
        var stream = AgentCodexStream(directory: directory)
        return lines.flatMap { stream.receive(line: $0) }
    }

    // MARK: - Fixtures

    private let threadStarted = #"{"type":"thread.started","thread_id":"01a10d84-2c0d-7460-be47-d27834158a41"}"#
    private let turnStarted = #"{"type":"turn.started"}"#

    private let completedTurn = #"""
    {"type":"turn.completed","usage":{"input_tokens":35162,"cached_input_tokens":26112,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0}}
    """#

    private let commandStarted = #"""
    {"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'echo codex-test'","aggregated_output":"","exit_code":null,"status":"in_progress"}}
    """#

    private let commandCompleted = #"""
    {"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'echo codex-test'","aggregated_output":"codex-test\n","exit_code":0,"status":"completed"}}
    """#

    private let fileStarted = #"""
    {"type":"item.started","item":{"id":"item_1","type":"file_change","changes":[{"path":"/tmp/agentchat-capture/codex-out.txt","kind":"add"}],"status":"in_progress"}}
    """#

    private let fileCompleted = #"""
    {"type":"item.completed","item":{"id":"item_1","type":"file_change","changes":[{"path":"/tmp/agentchat-capture/codex-out.txt","kind":"add"}],"status":"completed"}}
    """#

    private let agentMessage = #"""
    {"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"codex-test"}}
    """#

    private let failedTurn = #"""
    {"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-5.6-sol' model is not supported when using Codex with a ChatGPT account.\"}}"}}
    """#

    private let topLevelError = #"""
    {"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-5.6-sol' model is not supported when using Codex with a ChatGPT account.\"}}"}
    """#

    // MARK: - Tests

    func testTextTurn() {
        var stream = AgentCodexStream(directory: "/tmp/agentchat-capture")
        let payloads = [threadStarted, turnStarted, agentMessage, completedTurn]
            .flatMap { stream.receive(line: $0) }

        XCTAssertEqual(stream.cliSessionID, "01a10d84-2c0d-7460-be47-d27834158a41")
        guard case .sessionReady(let agentID, let sessionID, _, let directory) = payloads[0] else {
            return XCTFail("expected sessionReady first, got \(payloads[0])")
        }
        XCTAssertEqual(agentID, "codex")
        XCTAssertEqual(sessionID, "01a10d84-2c0d-7460-be47-d27834158a41")
        XCTAssertEqual(directory, "/tmp/agentchat-capture")

        XCTAssertEqual(payloads[1], .turnStarted)
        XCTAssertEqual(payloads[2], .textFinal(text: "codex-test"))
        guard case .turnFinished(let summary) = payloads[3] else {
            return XCTFail("expected turnFinished last, got \(payloads[3])")
        }
        XCTAssertTrue(summary.ok)
        XCTAssertEqual(summary.inputTokens, 35162)
        XCTAssertEqual(summary.outputTokens, 10)
        // Codex reports no dollars: the pill shows tokens and nothing pretends otherwise.
        XCTAssertNil(summary.costUSD)
    }

    func testCommandExecution() {
        let payloads = payloads([commandStarted, commandCompleted])

        guard case .toolStarted(let call) = payloads[0] else {
            return XCTFail("expected toolStarted, got \(payloads[0])")
        }
        XCTAssertEqual(call.id, "item_1")
        XCTAssertEqual(call.name, "command_execution")
        XCTAssertEqual(call.title, "Command")
        XCTAssertEqual(call.detail, "/bin/zsh -lc 'echo codex-test'")

        guard case .toolFinished(let callID, let ok, let output, let truncated) = payloads[1] else {
            return XCTFail("expected toolFinished, got \(payloads[1])")
        }
        XCTAssertEqual(callID, "item_1")
        XCTAssertTrue(ok)
        XCTAssertEqual(output, "codex-test\n")
        XCTAssertFalse(truncated)
    }

    func testFailedCommandIsNotOk() {
        let failed = #"""
        {"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"false","aggregated_output":"boom","exit_code":2,"status":"failed"}}
        """#
        let payloads = payloads([failed])
        guard case .toolFinished(_, let ok, _, _) = payloads[0] else {
            return XCTFail("expected toolFinished, got \(payloads[0])")
        }
        XCTAssertFalse(ok)
    }

    /// No diff is attached: this CLI's exec items carry none.
    func testFileChange() {
        let payloads = payloads([fileStarted, fileCompleted])

        guard case .toolStarted(let call) = payloads[0] else {
            return XCTFail("expected toolStarted, got \(payloads[0])")
        }
        XCTAssertEqual(call.title, "Edit")
        XCTAssertEqual(call.filePath, "/tmp/agentchat-capture/codex-out.txt")
        XCTAssertNil(call.diff)

        guard case .toolFinished(_, let ok, let output, _) = payloads[1] else {
            return XCTFail("expected toolFinished, got \(payloads[1])")
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(output, "add /tmp/agentchat-capture/codex-out.txt")
    }

    /// The failure arrives twice (top-level error and failed turn); the transcript gets one line.
    func testFailedTurnReportsTheAPISentenceOnce() {
        let payloads = payloads([topLevelError, failedTurn])
        XCTAssertEqual(
            payloads.first,
            .notice(text: "The 'gpt-5.6-sol' model is not supported when using Codex with a ChatGPT account.")
        )
        guard case .turnFinished(let summary) = payloads.last else {
            return XCTFail("expected turnFinished last, got \(String(describing: payloads.last))")
        }
        XCTAssertFalse(summary.ok)
        XCTAssertEqual(payloads.count, 2)
    }

    func testUnknownItemAndNonFatalWarning() {
        let warning = #"""
        {"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `gpt-5.6-sol` not found."}}
        """#
        let unknown = #"""
        {"type":"item.completed","item":{"id":"item_3","type":"something_new","value":1}}
        """#
        var stream = AgentCodexStream(directory: "/tmp")
        XCTAssertEqual(stream.receive(line: warning), [.notice(text: "Model metadata for `gpt-5.6-sol` not found.")])
        XCTAssertEqual(stream.receive(line: unknown).count, 1)
        XCTAssertEqual(stream.receive(line: unknown), [])
        XCTAssertEqual(stream.receive(line: "not json").count, 1)
    }

    func testResumeRepeatsTheThreadID() {
        let payloads = payloads([threadStarted, turnStarted, agentMessage, completedTurn])
        guard case .sessionReady(_, let sessionID, _, _) = payloads[0] else {
            return XCTFail("expected sessionReady, got \(payloads[0])")
        }
        XCTAssertEqual(sessionID, "01a10d84-2c0d-7460-be47-d27834158a41")
    }
}
