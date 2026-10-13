import XCTest

@testable import PeeringKit
import RemoteCore

/// Fixtures are lines captured from real runs: Claude Code's stream-json (`result`, `assistant` and
/// `rate_limit_event`), Codex's session log (`token_count`) and opencode's `step_finish`.
final class AgentUsageTests: XCTestCase {
    func testClaudeContextIsTheLastCallAndTotalsAddUp() {
        var stream = AgentClaudeStream()
        let assistant1 = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"one"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":14035,"cache_read_input_tokens":13636,"output_tokens":3}}}"#
        let result1 = #"{"type":"result","subtype":"success","total_cost_usd":0.0589012,"usage":{"input_tokens":2,"cache_creation_input_tokens":14035,"cache_read_input_tokens":13636,"output_tokens":3},"modelUsage":{"claude-sonnet-5-5":{"contextWindow":1000000}}}"#
        let assistant2 = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"two"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":2498,"cache_read_input_tokens":27671,"output_tokens":3}}}"#
        let result2 = #"{"type":"result","subtype":"success","total_cost_usd":0.0744614,"usage":{"input_tokens":2,"cache_creation_input_tokens":2498,"cache_read_input_tokens":27671,"output_tokens":3},"modelUsage":{"claude-sonnet-5-5":{"contextWindow":1000000}}}"#
        for line in [assistant1, result1, assistant2, result2] { _ = stream.receive(line: line) }

        XCTAssertEqual(stream.usage.contextUsedTokens, 2 + 2498 + 27671 + 3)
        XCTAssertEqual(stream.usage.contextWindowTokens, 1_000_000)
        XCTAssertEqual(stream.usage.inputTokens, (2 + 14035) + (2 + 2498))
        XCTAssertEqual(stream.usage.cachedTokens, 13636 + 27671)
        XCTAssertEqual(stream.usage.outputTokens, 6)
        XCTAssertEqual(stream.usage.costUSD, 0.0744614)
    }

    func testClaudeRateLimitWindows() {
        var stream = AgentClaudeStream()
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":0.02,"resetsAt":1791860400},"five_hour":{"utilization":0.07,"resetsAt":1791286200}}}}"#
        XCTAssertTrue(stream.receive(line: line).isEmpty)

        XCTAssertEqual(stream.usage.limits.map(\.label), ["5 hours", "7 days"])
        XCTAssertEqual(stream.usage.limits[0].usedFraction, 0.07, accuracy: 0.0001)
        XCTAssertEqual(stream.usage.limits[0].resetsAt, Date(timeIntervalSince1970: 1791286200))
    }

    func testCodexSessionLog() throws {
        let log = """
        {"timestamp":"t","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}
        {"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":90238,"cached_input_tokens":77568,"output_tokens":221,"reasoning_output_tokens":82,"total_tokens":90459},"last_token_usage":{"input_tokens":18368,"cached_input_tokens":17152,"output_tokens":5,"total_tokens":18373},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":1.0,"window_minutes":43200,"resets_at":1793435626},"secondary":null}}}
        """
        let usage = try XCTUnwrap(AgentCodexSessionLog.usage(fromLog: log))

        XCTAssertEqual(usage.contextUsedTokens, 18373)
        XCTAssertEqual(usage.contextWindowTokens, 258400)
        XCTAssertEqual(usage.inputTokens, 90238 - 77568)
        XCTAssertEqual(usage.cachedTokens, 77568)
        XCTAssertEqual(usage.outputTokens, 221)
        XCTAssertEqual(usage.limits.count, 1)
        XCTAssertEqual(usage.limits[0].label, "30 days")
        XCTAssertEqual(usage.limits[0].usedFraction, 0.01, accuracy: 0.0001)
    }

    func testACodexLogWithNoTokenCountIsNil() {
        XCTAssertNil(AgentCodexSessionLog.usage(fromLog: #"{"type":"event_msg","payload":{"type":"task_started"}}"#))
    }

    func testWindowLabels() {
        XCTAssertEqual(AgentCodexSessionLog.label(forMinutes: 300), "5 hours")
        XCTAssertEqual(AgentCodexSessionLog.label(forMinutes: 10080), "7 days")
        XCTAssertEqual(AgentCodexSessionLog.label(forMinutes: 1440), "1 day")
        XCTAssertEqual(AgentCodexSessionLog.label(forMinutes: 45), "45 minutes")
    }

    func testOpenCodeStepsAddUp() {
        var stream = AgentOpenCodeStream(directory: "/tmp")
        let step1 = #"{"type":"step_finish","sessionID":"s","part":{"reason":"tool-calls","tokens":{"input":16691,"output":88,"reasoning":33,"cache":{"write":0,"read":0}}}}"#
        let step2 = #"{"type":"step_finish","sessionID":"s","part":{"reason":"stop","tokens":{"input":89,"output":17,"reasoning":4,"cache":{"write":0,"read":16768}}}}"#
        for line in [step1, step2] { _ = stream.receive(line: line) }

        XCTAssertEqual(stream.usage.inputTokens, 16691 + 89)
        XCTAssertEqual(stream.usage.cachedTokens, 16768)
        XCTAssertEqual(stream.usage.outputTokens, 88 + 17)
        XCTAssertEqual(stream.usage.contextUsedTokens, 89 + 16768 + 17)
    }
}

final class AgentOpenCodeModelsTests: XCTestCase {
    func testTheModelOfTheLastAssistantMessage() {
        let export = #"{"info":{},"messages":[{"info":{"role":"user","model":{"providerID":"opencode","modelID":"big-pickle"}}},{"info":{"role":"assistant","modelID":"big-pickle","providerID":"opencode"}}]}"#
        XCTAssertEqual(
            AgentOpenCodeModels.lastModel(inExport: Data(export.utf8)),
            AgentOpenCodeModels.ModelID(provider: "opencode", model: "big-pickle")
        )
    }

    func testTheContextWindowOfOneModelInAVerboseListing() {
        let listing = """
        opencode/big-pickle
        {
          "id": "big-pickle",
          "limit": {
            "context": 200000,
            "output": 32000
          }
        }
        opencode/fledge-alpha-free
        {
          "id": "fledge-alpha-free",
          "limit": {
            "context": 1048576
          }
        }
        """
        let pickle = AgentOpenCodeModels.ModelID(provider: "opencode", model: "big-pickle")
        let fledge = AgentOpenCodeModels.ModelID(provider: "opencode", model: "fledge-alpha-free")
        XCTAssertEqual(AgentOpenCodeModels.contextWindow(of: pickle, inListing: listing), 200000)
        XCTAssertEqual(AgentOpenCodeModels.contextWindow(of: fledge, inListing: listing), 1048576)
        XCTAssertNil(AgentOpenCodeModels.contextWindow(
            of: .init(provider: "opencode", model: "missing"), inListing: listing
        ))
    }
}
