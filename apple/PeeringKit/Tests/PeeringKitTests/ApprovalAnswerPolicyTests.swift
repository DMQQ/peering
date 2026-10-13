import Testing
@testable import PeeringKit

@Suite struct ApprovalAnswerPolicyTests {
    private func outcome(
        sent: Bool = true, resolved: Bool = false, ready: Bool = true, waited: Double = 0
    ) -> ApprovalAnswerPolicy.Outcome {
        ApprovalAnswerPolicy.outcome(wasSent: sent, macResolved: resolved, sessionReady: ready, waited: waited)
    }

    @Test func anAnswerNeverHandedToAConnectionFailsAtOnce() {
        #expect(outcome(sent: false) == .failed)
        #expect(outcome(sent: false, resolved: true) == .failed)
    }

    @Test func aSentAnswerIsNotDeliveredUntilTheMacResolvesIt() {
        #expect(outcome(waited: 0) == .waiting)
        #expect(outcome(waited: 14) == .waiting)
    }

    @Test func theMacResolvingItConfirmsIt() {
        #expect(outcome(resolved: true, waited: 3) == .confirmed)
    }

    @Test func aConfirmationThatLandedWithTheLinkClosingStillCounts() {
        #expect(outcome(resolved: true, ready: false, waited: 3) == .confirmed)
    }

    @Test func aLinkThatDropsBeforeTheConfirmationFails() {
        #expect(outcome(ready: false, waited: 2) == .failed)
    }

    @Test func silenceForTheWholeWindowFails() {
        #expect(outcome(waited: 15) == .failed)
        #expect(outcome(waited: 60) == .failed)
    }
}
