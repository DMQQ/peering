import Testing

@testable import RemoteCore
@testable import MacCastKit

@Suite struct AgentClaudeFailureReasonTests {
    private func lines(_ result: String) -> [AgentStreamEvent.Payload] {
        var stream = AgentClaudeStream()
        return stream.receive(line: result)
    }

    @Test func aFailedTurnSaysWhyBeforeItsSummary() {
        let payloads = lines(#"{"type":"result","is_error":true,"result":"Prompt is too long"}"#)
        #expect(payloads.count == 2)
        #expect(payloads[0] == .notice(text: "Prompt is too long"))
        if case .turnFinished(let summary) = payloads[1] { #expect(!summary.ok) } else { Issue.record("expected the summary last") }
    }

    @Test func aSuccessfulTurnAddsNoNotice() {
        let payloads = lines(#"{"type":"result","is_error":false,"result":"Done."}"#)
        #expect(payloads.count == 1)
    }

    @Test func aStoppedTurnIsNotBlamed() {
        let payloads = lines(#"{"type":"result","is_error":true,"terminal_reason":"aborted_streaming","result":"Interrupted"}"#)
        #expect(payloads.count == 1)
    }
}
