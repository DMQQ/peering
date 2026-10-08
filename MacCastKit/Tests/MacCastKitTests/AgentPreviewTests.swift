import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

struct AgentPreviewTests {
    private func transcript(_ payloads: [AgentStreamEvent.Payload]) -> AgentTranscript {
        var transcript = AgentTranscript()
        for (offset, payload) in payloads.enumerated() {
            transcript.apply(AgentStreamEvent(index: UInt64(offset + 1), payload: payload))
        }
        return transcript
    }

    @Test func emptyTranscriptHasNoPreview() {
        #expect(AgentTranscript().preview == nil)
    }

    @Test func lastSpokenLineWinsAndMarkdownIsStripped() {
        let said = transcript([
            .userPrompt(text: "do it"),
            .turnStarted,
            .textFinal(text: "## Done\nI ran `npm test` and **all** passed"),
        ])
        #expect(said.preview == "Done I ran npm test and all passed")
    }

    @Test func aToolOnlyTailFallsBackToTheEarlierSpeech() {
        let said = transcript([
            .userPrompt(text: "go"),
            .turnStarted,
            .toolStarted(call: AgentToolCall(id: "1", name: "Bash", title: "Run")),
        ])
        #expect(said.preview == "go")
    }

    @Test func previewIsCapped() {
        let said = transcript([.userPrompt(text: String(repeating: "x", count: 300))])
        #expect(said.preview?.count == 140)
    }

    @Test func textThatStripsToNothingIsSkipped() {
        let said = transcript([.userPrompt(text: "hello"), .turnStarted, .textFinal(text: "```\n```")])
        #expect(said.preview == "hello")
    }
}
