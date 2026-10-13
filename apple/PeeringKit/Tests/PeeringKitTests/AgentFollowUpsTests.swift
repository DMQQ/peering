import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

struct AgentFollowUpsTests {
    private func transcript(_ payloads: [AgentStreamEvent.Payload]) -> AgentTranscript {
        var transcript = AgentTranscript()
        for payload in payloads { transcript.apply(payload) }
        return transcript
    }

    private func call(_ id: String, name: String, detail: String? = nil) -> AgentStreamEvent.Payload {
        .toolStarted(call: AgentToolCall(id: id, name: name, title: name, detail: detail))
    }

    private let done = AgentStreamEvent.Payload.turnFinished(summary: AgentTurnSummary(ok: true))

    @Test func anEditedProjectOffersReviewTestsAndASummary() {
        let found = AgentFollowUps.suggestions(for: transcript([
            .userPrompt(text: "fix it"),
            call("1", name: "Edit"),
            .toolFinished(callID: "1", ok: true, output: nil, truncated: false),
            done,
        ]))
        #expect(found == [.reviewChanges, .runTests, .summarizeChanges])
    }

    @Test func aTurnThatAlreadyRanTestsDoesNotOfferThemAgain() {
        let found = AgentFollowUps.suggestions(for: transcript([
            .userPrompt(text: "fix it"),
            call("1", name: "Edit"),
            .toolFinished(callID: "1", ok: true, output: nil, truncated: false),
            call("2", name: "Bash", detail: "swift test"),
            .toolFinished(callID: "2", ok: true, output: nil, truncated: false),
            done,
        ]))
        #expect(found == [.reviewChanges, .summarizeChanges])
    }

    @Test func aTurnThatOnlyAnsweredOffersNothing() {
        let found = AgentFollowUps.suggestions(for: transcript([
            .userPrompt(text: "what does this do"),
            .textFinal(text: "It parses."),
            done,
        ]))
        #expect(found.isEmpty)
    }

    @Test func nothingIsOfferedWhileTheAgentIsWorking() {
        let found = AgentFollowUps.suggestions(for: transcript([
            .userPrompt(text: "fix it"),
            call("1", name: "Edit"),
            .toolFinished(callID: "1", ok: true, output: nil, truncated: false),
        ]))
        #expect(found.isEmpty)
    }

    @Test func anEarlierTurnsEditsDoNotCountForALaterOne() {
        let found = AgentFollowUps.suggestions(for: transcript([
            .userPrompt(text: "fix it"),
            call("1", name: "Edit"),
            .toolFinished(callID: "1", ok: true, output: nil, truncated: false),
            done,
            .userPrompt(text: "thanks"),
            .textFinal(text: "Welcome."),
            done,
        ]))
        #expect(found.isEmpty)
    }
}
