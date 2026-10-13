import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

@Suite struct AgentTranscriptBufferTests {
    private func turn(_ buffer: inout AgentTranscriptBuffer, _ prompt: String, output: String? = nil) {
        buffer.append(.userPrompt(text: prompt))
        buffer.append(.turnStarted)
        if let output {
            buffer.append(.toolStarted(call: AgentToolCall(id: prompt, name: "Bash", title: "Bash")))
            buffer.append(.toolFinished(callID: prompt, ok: true, output: output, truncated: false))
        }
    }

    @Test func indicesStartAtOneAndGrow() {
        var buffer = AgentTranscriptBuffer()
        let first = buffer.append(.turnStarted)
        let second = buffer.append(.notice(text: "x"))
        #expect(first.index == 1)
        #expect(second.index == 2)
        #expect(buffer.lastIndex == 2)
    }

    @Test func finalTextReplacesTheDeltasThatBuiltIt() {
        var buffer = AgentTranscriptBuffer()
        buffer.append(.userPrompt(text: "hi"))
        buffer.append(.textDelta(text: "He"))
        buffer.append(.textDelta(text: "llo"))
        let final = buffer.append(.textFinal(text: "Hello"))
        #expect(buffer.events.count == 2)
        #expect(final.index == 4)
        #expect(buffer.lastIndex == 4)
    }

    @Test func deltasBeforeAToolStayBecauseTheyAreNotTrailing() {
        var buffer = AgentTranscriptBuffer()
        buffer.append(.textDelta(text: "a"))
        buffer.append(.toolStarted(call: AgentToolCall(id: "t", name: "Bash", title: "Bash")))
        buffer.append(.textFinal(text: "b"))
        #expect(buffer.events.count == 3)
    }

    @Test func chunksRespectTheEventBudgetAndSkipWhatWasSeen() {
        var buffer = AgentTranscriptBuffer()
        for _ in 0..<5 { buffer.append(.turnStarted) }
        let chunks = buffer.chunks(since: 1, byteBudget: 1_000_000, eventBudget: 2)
        #expect(chunks.map(\.count) == [2, 2])
        #expect(chunks.first?.first?.index == 2)
    }

    @Test func chunksRespectTheByteBudget() {
        var buffer = AgentTranscriptBuffer()
        for _ in 0..<4 { buffer.append(.notice(text: String(repeating: "a", count: 100))) }
        let chunks = buffer.chunks(since: 0, byteBudget: 250)
        #expect(chunks.map(\.count) == [2, 2])
    }

    @Test func nothingToReplayGivesNoChunks() {
        var buffer = AgentTranscriptBuffer()
        buffer.append(.turnStarted)
        #expect(buffer.chunks(since: 1, byteBudget: 100).isEmpty)
    }

    @Test func overTheLimitTheOldestTurnGoesFirst() {
        var buffer = AgentTranscriptBuffer()
        turn(&buffer, "one", output: String(repeating: "a", count: 500))
        turn(&buffer, "two")
        buffer.append(.notice(text: String(repeating: "b", count: 500)), limit: 700)
        #expect(buffer.truncatedAtFront)
        if case .userPrompt(let text) = buffer.events.first?.payload { #expect(text == "two") } else { Issue.record("first event is not the second prompt") }
    }

    @Test func oneHugeTurnLosesToolOutputInsteadOfItsShape() {
        var buffer = AgentTranscriptBuffer()
        turn(&buffer, "only", output: String(repeating: "a", count: 5_000))
        buffer.append(.notice(text: "tail"), limit: 1_000)
        #expect(!buffer.truncatedAtFront)
        let outputs = buffer.events.compactMap { event -> (String?, Bool)? in
            if case .toolFinished(_, _, let output, let truncated) = event.payload { return (output, truncated) }
            return nil
        }
        #expect(outputs.count == 1)
        #expect(outputs.first?.0 == nil)
        #expect(outputs.first?.1 == true)
    }

    @Test func restoringKeepsIndicesMonotonic() {
        var buffer = AgentTranscriptBuffer(
            restoring: [AgentStreamEvent(index: 7, payload: .turnStarted)], nextIndex: 3, truncatedAtFront: true
        )
        let next = buffer.append(.notice(text: "x"))
        #expect(next.index == 8)
        #expect(buffer.truncatedAtFront)
    }
}

extension AgentTranscriptBufferTests {
    private func ask(_ id: String) -> AgentStreamEvent.Payload {
        .approvalRequested(approvalID: id, call: AgentToolCall(id: id, name: "Bash", title: "Bash"), reason: nil)
    }

    @Test func anAskWithoutAnAnswerIsUnresolved() {
        var buffer = AgentTranscriptBuffer()
        buffer.append(ask("a"))
        buffer.append(ask("b"))
        buffer.append(.approvalResolved(approvalID: "a", decision: .allow))
        #expect(buffer.unresolvedApprovalIDs == ["b"])
    }

    @Test func aFinishedTurnClosesEveryAsk() {
        var buffer = AgentTranscriptBuffer()
        buffer.append(ask("a"))
        buffer.append(.turnFinished(summary: AgentTurnSummary(ok: true)))
        #expect(buffer.unresolvedApprovalIDs.isEmpty)
    }
}
