import XCTest
@testable import MacCastKit
import RemoteCore

/// Whether a disconnected Mac is being put back; four places must agree on the answer.
final class SessionResumeTests: XCTestCase {
    private func isUnderWay(
        hasBeenReady: Bool = true,
        userEndedDeliberately: Bool = false,
        hasGivenUpResuming: Bool = false,
        isReconnecting: Bool = false,
        phase: ClientSession.Phase = .failed("The Mac stopped answering.")
    ) -> Bool {
        SessionResume.isUnderWay(
            hasBeenReady: hasBeenReady,
            userEndedDeliberately: userEndedDeliberately,
            hasGivenUpResuming: hasGivenUpResuming,
            isReconnecting: isReconnecting,
            phase: phase
        )
    }

    func testADropWithARetryArmedIsUnderWay() {
        XCTAssertTrue(isUnderWay(isReconnecting: true))
    }

    func testARetryThatIsDiallingIsUnderWay() {
        XCTAssertTrue(isUnderWay(phase: .connecting))
        XCTAssertTrue(isUnderWay(phase: .handshaking))
    }

    /// Between the ladder building a session and its first phase: answering no flickers the picker in and out.
    func testTheTurnAcrossADialIsUnderWay() {
        XCTAssertTrue(isUnderWay(phase: .idle))
    }

    func testAConnectionBeingMadeIsNotAResume() {
        XCTAssertFalse(isUnderWay(hasBeenReady: false, phase: .connecting))
        XCTAssertFalse(isUnderWay(hasBeenReady: false, phase: .idle))
    }

    func testAColdLaunchRestoreStopsAfterItsFirstFailedConnection() {
        XCTAssertEqual(
            SessionResume.failureAction(hasBeenReady: false),
            .stopAndShowFailure
        )
    }

    func testADroppedLiveSessionKeepsItsReconnectLadderAfterAFailedAttempt() {
        XCTAssertEqual(
            SessionResume.failureAction(hasBeenReady: true),
            .retrySilently
        )
    }

    /// userEndedDeliberately is consumed by the first transition, so a deliberate disconnect must not read as a resume (black screen, no way back).
    func testASessionTheUserEndedIsNotAResume() {
        XCTAssertFalse(isUnderWay(phase: .disconnected))
    }

    /// Ladder exhausted: the phase will never change, so keeping the screen would freeze a frame.
    func testALadderThatHasGivenUpIsNotAResume() {
        XCTAssertFalse(isUnderWay(hasGivenUpResuming: true))
        XCTAssertFalse(isUnderWay(hasGivenUpResuming: true, phase: .connecting))
    }

    func testAFailureWithNothingArmedIsNotAResume() {
        XCTAssertFalse(isUnderWay(phase: .failed("The Mac refused the connection.")))
    }

    func testTheUsersOwnDoingOutranksEverything() {
        XCTAssertFalse(isUnderWay(userEndedDeliberately: true, isReconnecting: true))
        XCTAssertFalse(isUnderWay(userEndedDeliberately: true, phase: .connecting))
    }
}
