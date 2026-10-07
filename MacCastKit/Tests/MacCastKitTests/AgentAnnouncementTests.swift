import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

struct AgentAnnouncementTests {
    private func transcript(_ payloads: [AgentStreamEvent.Payload]) -> AgentTranscript {
        var transcript = AgentTranscript()
        for (offset, payload) in payloads.enumerated() {
            transcript.apply(AgentStreamEvent(index: UInt64(offset + 1), payload: payload))
        }
        return transcript
    }

    private let call = AgentToolCall(id: "t1", name: "Bash", title: "Run", detail: "ls")

    @Test func approvalNamesTheFirstPendingAsk() {
        let held = transcript([
            .turnStarted,
            .toolStarted(call: call),
            .approvalRequested(approvalID: "a1", call: call, reason: "why"),
        ])
        let announcement = AgentAnnouncement.of(from: .working, to: .awaitingApproval, isLoaded: true, transcript: held)
        #expect(announcement == .approval(AgentApproval(id: "a1", call: call, reason: "why")))
    }

    @Test func approvalWithNothingPendingSaysNothing() {
        let announcement = AgentAnnouncement.of(from: .working, to: .awaitingApproval, isLoaded: true, transcript: AgentTranscript())
        #expect(announcement == nil)
    }

    @Test func finishedCarriesTheLastReply() {
        let done = transcript([.turnStarted, .textFinal(text: "first"), .textFinal(text: "last")])
        let announcement = AgentAnnouncement.of(from: .working, to: .idle, isLoaded: true, transcript: done)
        guard case .finished(let reply) = announcement else {
            Issue.record("expected finished")
            return
        }
        #expect(reply == "last")
    }

    @Test func finishedKeepsOnlyTheTailOfALongReply() {
        let long = String(repeating: "a", count: 700)
        let done = transcript([.turnStarted, .textFinal(text: long)])
        guard case .finished(let reply) = AgentAnnouncement.of(from: .working, to: .idle, isLoaded: true, transcript: done) else {
            Issue.record("expected finished")
            return
        }
        #expect(reply?.count == 600)
    }

    @Test func failureIsAnnouncedFromAnyState() {
        #expect(AgentAnnouncement.of(from: .idle, to: .failed, isLoaded: true, transcript: AgentTranscript()) == .failed)
    }

    @Test func nothingBeforeHistoryHasLoadedOrWithoutAChange() {
        #expect(AgentAnnouncement.of(from: .working, to: .idle, isLoaded: false, transcript: AgentTranscript()) == nil)
        #expect(AgentAnnouncement.of(from: .idle, to: .idle, isLoaded: true, transcript: AgentTranscript()) == nil)
    }

    @Test func startingAndExitingAreNotAnnounced() {
        #expect(AgentAnnouncement.of(from: .idle, to: .working, isLoaded: true, transcript: AgentTranscript()) == nil)
        #expect(AgentAnnouncement.of(from: .working, to: .exited, isLoaded: true, transcript: AgentTranscript()) == nil)
    }
}
