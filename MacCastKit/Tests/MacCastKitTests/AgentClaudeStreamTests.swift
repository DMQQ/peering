import XCTest

@testable import MacCastKit
import RemoteCore

/// Fixtures are lines captured from a real Claude Code 2.1.289 process (`claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --replay-user-messages --permission-prompt-tool stdio`), trimmed to the fields the parser reads.
final class AgentClaudeStreamTests: XCTestCase {
    private func payloads(_ lines: [String]) -> [AgentStreamEvent.Payload] {
        var stream = AgentClaudeStream()
        return lines.flatMap { stream.receive(line: $0) }
    }

    // MARK: - Fixtures

    private let initLine = #"""
    {"type":"system","subtype":"init","cwd":"/private/tmp/agentchat-capture","session_id":"2398a6db-8e32-4169-b1ca-09bcfdb80e58","model":"deepseek-flash[1m]","permissionMode":"default","capabilities":["interrupt_receipt_v1","interrupt_cancel_queued_v1"]}
    """#

    private let replayedPrompt = #"""
    {"type":"user","message":{"role":"user","content":"Reply with exactly the word: ready"},"session_id":"2398a6db-8e32-4169-b1ca-09bcfdb80e58","parent_tool_use_id":null,"uuid":"fc4d05e5","timestamp":"2026-10-05T19:07:07.540Z","isReplay":true}
    """#

    private func textDelta(_ text: String) -> String {
        #"{"type":"stream_event","uuid":"u1","session_id":"s","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}"#
    }

    private let assistantText = #"""
    {"type":"assistant","message":{"id":"84bd3337","type":"message","role":"assistant","model":"deepseek-flash","content":[{"type":"text","text":"ready"}],"stop_reason":null,"usage":{"input_tokens":36785,"output_tokens":0}},"parent_tool_use_id":null,"session_id":"s","uuid":"b3bfb4af","timestamp":"2026-10-05T19:07:09.186Z"}
    """#

    private let assistantToolUse = #"""
    {"type":"assistant","message":{"id":"m1","role":"assistant","model":"m","content":[{"type":"tool_use","id":"call_00_EklvM8Zu3twQyvboNvfy2187","name":"Bash","input":{"command":"echo peering-test","description":"Print peering-test"}}]},"parent_tool_use_id":null,"session_id":"s","uuid":"u2"}
    """#

    private let toolResult = #"""
    {"type":"user","message":{"role":"user","content":[{"tool_use_id":"call_00_EklvM8Zu3twQyvboNvfy2187","type":"tool_result","content":"peering-test","is_error":false}]},"parent_tool_use_id":null,"session_id":"s","uuid":"u3","tool_use_result":{"stdout":"peering-test","stderr":""}}
    """#

    private let deniedToolResult = #"""
    {"type":"user","message":{"role":"user","content":[{"tool_use_id":"call_00_Liez","type":"tool_result","content":"Denied from the capture driver.","is_error":true}]},"parent_tool_use_id":null,"session_id":"s","uuid":"u4"}
    """#

    private let approvalRequest = #"""
    {"type":"control_request","request_id":"49f17c21-744b-4bc7-a5ee-4ecf7225a13c","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"rm -f /tmp/agentchat-capture/nonexistent.txt","description":"Remove nonexistent.txt from /tmp/agentchat-capture"},"description":"Remove nonexistent.txt from /tmp/agentchat-capture","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -f /tmp/x"}],"behavior":"allow","destination":"localSettings"}],"blocked_path":"/tmp/agentchat-capture/nonexistent.txt","tool_use_id":"call_00_Liezk1XgeNgoKbBzb6sI4460"}}
    """#

    private let resultLine = #"""
    {"type":"result","subtype":"success","is_error":false,"duration_api_ms":1616,"duration_ms":1641,"total_cost_usd":0.196795,"usage":{"input_tokens":39349,"output_tokens":2},"modelUsage":{"deepseek-flash[1m]":{"costUSD":0.196795}},"permission_denials":[],"terminal_reason":"completed","num_turns":1,"session_id":"2398a6db","result":"ready"}
    """#

    private let secondResultLine = #"""
    {"type":"result","subtype":"success","is_error":false,"duration_ms":1230,"total_cost_usd":0.217539,"usage":{"input_tokens":222,"output_tokens":2},"terminal_reason":"completed","num_turns":1,"session_id":"2398a6db"}
    """#

    // MARK: - Tests

    func testTextTurn() {
        var stream = AgentClaudeStream()
        let payloads = [initLine, replayedPrompt, textDelta("rea"), textDelta("dy"), assistantText, resultLine]
            .flatMap { stream.receive(line: $0) }

        XCTAssertEqual(stream.cliSessionID, "2398a6db-8e32-4169-b1ca-09bcfdb80e58")
        guard case .sessionReady(let agentID, let sessionID, let model, let directory) = payloads[0] else {
            return XCTFail("expected sessionReady first, got \(payloads[0])")
        }
        XCTAssertEqual(agentID, "claude")
        XCTAssertEqual(sessionID, "2398a6db-8e32-4169-b1ca-09bcfdb80e58")
        XCTAssertEqual(model, "deepseek-flash[1m]")
        XCTAssertEqual(directory, "/private/tmp/agentchat-capture")

        // The prompt echo produces nothing: the host writes prompts into the transcript itself.
        XCTAssertEqual(payloads.count, 5)
        XCTAssertEqual(payloads[1], .textDelta(text: "rea"))
        XCTAssertEqual(payloads[2], .textDelta(text: "dy"))
        XCTAssertEqual(payloads[3], .textFinal(text: "ready"))

        guard case .turnFinished(let summary) = payloads[4] else {
            return XCTFail("expected turnFinished last, got \(payloads[4])")
        }
        XCTAssertTrue(summary.ok)
        XCTAssertFalse(summary.stopped)
        XCTAssertEqual(summary.costUSD ?? 0, 0.196795, accuracy: 0.000_001)
        XCTAssertEqual(summary.inputTokens, 39349)
        XCTAssertEqual(summary.outputTokens, 2)
        XCTAssertEqual(summary.duration ?? 0, 1.641, accuracy: 0.001)
        XCTAssertEqual(summary.model, "deepseek-flash[1m]")
    }

    func testCostIsPerTurn() {
        let payloads = payloads([initLine, resultLine, secondResultLine])
        guard case .turnFinished(let first) = payloads[1], case .turnFinished(let second) = payloads[2] else {
            return XCTFail("expected two summaries, got \(payloads)")
        }
        XCTAssertEqual(first.costUSD ?? 0, 0.196795, accuracy: 0.000_001)
        XCTAssertEqual(second.costUSD ?? 0, 0.020744, accuracy: 0.000_001)
        XCTAssertEqual(second.inputTokens, 222)
    }

    func testToolCallAndResult() {
        let payloads = payloads([assistantToolUse, toolResult])

        guard case .toolStarted(let call) = payloads[0] else {
            return XCTFail("expected toolStarted, got \(payloads[0])")
        }
        XCTAssertEqual(call.id, "call_00_EklvM8Zu3twQyvboNvfy2187")
        XCTAssertEqual(call.name, "Bash")
        XCTAssertEqual(call.title, "Bash")
        XCTAssertEqual(call.detail, "echo peering-test")

        guard case .toolFinished(let callID, let ok, let output, let truncated) = payloads[1] else {
            return XCTFail("expected toolFinished, got \(payloads[1])")
        }
        XCTAssertEqual(callID, call.id)
        XCTAssertTrue(ok)
        XCTAssertEqual(output, "peering-test")
        XCTAssertFalse(truncated)
    }

    func testDeniedToolResult() {
        let payloads = payloads([deniedToolResult])
        guard case .toolFinished(_, let ok, let output, _) = payloads[0] else {
            return XCTFail("expected toolFinished, got \(payloads[0])")
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(output, "Denied from the capture driver.")
    }

    func testApprovalRequest() {
        let payloads = payloads([approvalRequest])
        guard case .approvalRequested(let approvalID, let call, let reason) = payloads[0] else {
            return XCTFail("expected approvalRequested, got \(payloads[0])")
        }
        // The approval id is the envelope's request_id, which is what the answer must echo, and
        // the call's id is the tool_use id, which is what ties the ask to the card it belongs to.
        XCTAssertEqual(approvalID, "49f17c21-744b-4bc7-a5ee-4ecf7225a13c")
        XCTAssertEqual(call.id, "call_00_Liezk1XgeNgoKbBzb6sI4460")
        XCTAssertEqual(call.name, "Bash")
        XCTAssertEqual(call.title, "Bash")
        XCTAssertEqual(call.detail, "rm -f /tmp/agentchat-capture/nonexistent.txt")
        XCTAssertEqual(reason, "Remove nonexistent.txt from /tmp/agentchat-capture")
    }

    func testEditBuildsDiff() {
        let edit = #"""
        {"type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"toolu_02","name":"Edit","input":{"file_path":"/app/src/a.ts","old_string":"const a = 1;","new_string":"const a = 2;"}}]},"parent_tool_use_id":null,"session_id":"s","uuid":"u5"}
        """#
        let payloads = payloads([edit])
        guard case .toolStarted(let call) = payloads[0] else {
            return XCTFail("expected toolStarted, got \(payloads[0])")
        }
        XCTAssertEqual(call.filePath, "/app/src/a.ts")
        XCTAssertEqual(call.detail, "/app/src/a.ts")
        let diff = call.diff ?? ""
        XCTAssertTrue(diff.contains("--- /app/src/a.ts"), diff)
        XCTAssertTrue(diff.contains("-const a = 1;"), diff)
        XCTAssertTrue(diff.contains("+const a = 2;"), diff)
    }

    func testInterruptedResult() {
        let interrupted = #"""
        {"type":"result","subtype":"success","is_error":false,"terminal_reason":"aborted_streaming","num_turns":1,"session_id":"s"}
        """#
        let payloads = payloads([interrupted])
        guard case .turnFinished(let summary) = payloads[0] else {
            return XCTFail("expected turnFinished, got \(payloads[0])")
        }
        XCTAssertTrue(summary.stopped)
    }

    func testNoiseHandling() {
        let status = #"{"type":"system","subtype":"status","status":"requesting","session_id":"s"}"#
        let thinking = #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":5,"session_id":"s"}"#
        let unknown = #"{"type":"something_new","session_id":"s"}"#
        let garbage = "not json at all"

        var stream = AgentClaudeStream()
        XCTAssertTrue(status.isEmpty == false)
        XCTAssertEqual(stream.receive(line: status), [])
        XCTAssertEqual(stream.receive(line: thinking), [])
        XCTAssertEqual(stream.receive(line: unknown).count, 1)
        XCTAssertEqual(stream.receive(line: unknown), [])
        XCTAssertEqual(stream.receive(line: garbage).count, 1)
    }

    func testReplayEchoAndControlResponsesAreQuiet() {
        var stream = AgentClaudeStream()
        XCTAssertEqual(stream.receive(line: replayedPrompt), [])
        let receipt = #"{"type":"control_response","response":{"subtype":"success","request_id":"req_1","response":{"still_queued":[],"cancelled":[]}}}"#
        XCTAssertEqual(stream.receive(line: receipt), [])
    }

    func testApprovalInputIsHeldForTheAnswer() {
        var stream = AgentClaudeStream()
        _ = stream.receive(line: approvalRequest)
        let input = stream.takeApprovalInput("49f17c21-744b-4bc7-a5ee-4ecf7225a13c")
        XCTAssertEqual(input?["command"] as? String, "rm -f /tmp/agentchat-capture/nonexistent.txt")
        XCTAssertNil(stream.takeApprovalInput("49f17c21-744b-4bc7-a5ee-4ecf7225a13c"))
    }

    /// Captured from a real `AskUserQuestion` control request on 2.1.289.
    func testQuestionAskCarriesTheQuestionAndChoices() {
        let question = #"""
        {"type":"control_request","request_id":"82feeba8-70c5-48a1-b269-d515d366a09b","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","display_name":"AskUserQuestion","input":{"questions":[{"question":"Which colour do you prefer?","header":"Colour","options":[{"label":"Red","description":"You prefer red."},{"label":"Blue","description":"You prefer blue."}],"multiSelect":false}]},"tool_use_id":"call_00_IIERyVtJGtpj3qPKdSPq3571","requires_user_interaction":true}}
        """#
        var stream = AgentClaudeStream()
        let payloads = stream.receive(line: question)
        guard case .approvalRequested(let approvalID, let call, _) = payloads[0] else {
            return XCTFail("expected approvalRequested, got \(payloads[0])")
        }
        XCTAssertEqual(approvalID, "82feeba8-70c5-48a1-b269-d515d366a09b")
        XCTAssertEqual(call.name, "AskUserQuestion")
        XCTAssertEqual(call.title, "Colour")
        XCTAssertEqual(call.detail, "Which colour do you prefer?")
        XCTAssertEqual(call.questions?.count, 1)
        XCTAssertEqual(call.questions?.first?.options.map(\.label), ["Red", "Blue"])
        XCTAssertEqual(call.questions?.first?.options.first?.detail, "You prefer red.")
        XCTAssertNotNil(stream.takeApprovalInput(approvalID))
    }

    func testAgentLaunchResultIsNotShownToTheUser() {
        let line = #"""
        {"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully. (This tool result is internal metadata)\nagentId: a31e (internal ID - do not mention to user.)"}]}]},"parent_tool_use_id":null,"session_id":"s"}
        """#
        guard case .toolFinished(_, let ok, let output, _) = payloads([line])[0] else {
            return XCTFail("expected toolFinished")
        }
        XCTAssertTrue(ok)
        XCTAssertNil(output)
    }

    func testSeveralQuestionsAreAllCarried() {
        let ask = #"""
        {"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Colour?","header":"Colour","options":[{"label":"Red"}]},{"question":"Size?","header":"Size","options":[{"label":"Small"},{"label":"Large"}]},{"question":"Shape?","header":"Shape","options":[{"label":"Round"}]}]},"tool_use_id":"t"}}
        """#
        var stream = AgentClaudeStream()
        guard case .approvalRequested(_, let call, _) = stream.receive(line: ask)[0] else {
            return XCTFail("expected approvalRequested")
        }
        XCTAssertEqual(call.questions?.map(\.question), ["Colour?", "Size?", "Shape?"])
        XCTAssertEqual(call.questions?[1].options.map(\.label), ["Small", "Large"])
    }

    func testSubagentTrafficIsFiledUnderItsParent() {
        let subagentTool = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"ls"}}]},"parent_tool_use_id":"toolu_parent","session_id":"s","uuid":"u6"}
        """#
        let subagentDelta = #"{"type":"stream_event","parent_tool_use_id":"toolu_parent","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}"#
        let result = payloads([subagentTool, subagentDelta])
        XCTAssertEqual(result.count, 2)
        for payload in result {
            guard case .child(let parent, _) = payload else { return XCTFail("expected child, got \(payload)") }
            XCTAssertEqual(parent, "toolu_parent")
        }
    }

    func testLongOutputIsTruncated() {
        let long = String(repeating: "x", count: 40_000)
        let line = #"""
        {"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"\#(long)"}]},"parent_tool_use_id":null,"session_id":"s"}
        """#
        let payloads = payloads([line])
        guard case .toolFinished(_, _, let output, let truncated) = payloads[0] else {
            return XCTFail("expected toolFinished, got \(payloads[0])")
        }
        XCTAssertTrue(truncated)
        XCTAssertEqual(output?.utf8.count, AgentLimits.maximumToolOutputBytes)
    }
}
