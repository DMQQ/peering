import RemoteCore
import Testing
@testable import PeeringKit

@Suite struct SessionResumeTerminalTests {
    @Test(arguments: [
        ClientSession.FailureReason.pinMismatch, .hostIDMismatch, .noPinOnFile, .protocolMismatch,
    ])
    func aTrustOrVersionProblemStopsTheLadderEvenAfterTheMacWasReady(reason: ClientSession.FailureReason) {
        #expect(SessionResume.failureAction(hasBeenReady: true, reason: reason) == .stopAndShowFailure)
    }

    @Test(arguments: [
        ClientSession.FailureReason.timedOut, .transport, .relay, .refused, .hostClosed, .pinsUnreadable, .handshake, .other,
    ])
    func anOrdinaryFailureStillRetriesAfterTheMacWasReady(reason: ClientSession.FailureReason) {
        #expect(SessionResume.failureAction(hasBeenReady: true, reason: reason) == .retrySilently)
    }

    @Test func noReasonFallsBackToWhetherTheMacWasReady() {
        #expect(SessionResume.failureAction(hasBeenReady: true, reason: nil) == .retrySilently)
        #expect(SessionResume.failureAction(hasBeenReady: false, reason: nil) == .stopAndShowFailure)
    }
}
