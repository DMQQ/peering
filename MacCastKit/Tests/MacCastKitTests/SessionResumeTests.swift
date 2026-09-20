import XCTest
@testable import MacCastKit
import RemoteCore

/// The rule that decides whether a Mac that is not connected is being put back.
///
/// It is worth its own file because it is asked from four places that all have to agree — the
/// screen that stays up, the card that stays down, the banner that stays quiet and the ladder that
/// is shorter — and because two of its cases are states that nothing else can tell apart.
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

    /// The turn between the ladder building its new session and that session emitting its first
    /// phase. Nothing is armed and nothing holds a session, so every fact except the phase says
    /// no, and answering no here is a picker that flickers in and straight back out during a
    /// handover.
    func testTheTurnAcrossADialIsUnderWay() {
        XCTAssertTrue(isUnderWay(phase: .idle))
    }

    func testAConnectionBeingMadeIsNotAResume() {
        XCTAssertFalse(isUnderWay(hasBeenReady: false, phase: .connecting))
        XCTAssertFalse(isUnderWay(hasBeenReady: false, phase: .idle))
    }

    /// **The case that made this a rule rather than a flag.** `userEndedDeliberately` is consumed
    /// by the first transition that reads it, so by the time the session is sitting at
    /// `.disconnected` there is nothing left on it that says the user asked for this. Read as a
    /// resume, the screen keeps a picture whose renderer has been detached: a black screen with no
    /// way back to the picker.
    func testASessionTheUserEndedIsNotAResume() {
        XCTAssertFalse(isUnderWay(phase: .disconnected))
    }

    /// The same shape, one state over: the ladder ran out and the phase will never change again.
    /// Keeping the screen here would leave a frozen frame up for ever, which is the failure this
    /// whole change has to be careful not to trade itself for.
    func testALadderThatHasGivenUpIsNotAResume() {
        XCTAssertFalse(isUnderWay(hasGivenUpResuming: true))
        XCTAssertFalse(isUnderWay(hasGivenUpResuming: true, phase: .connecting))
    }

    /// A drop that no ladder will pick up, which is what a declined pairing prompt and an
    /// exhausted relay allowance both leave behind.
    func testAFailureWithNothingArmedIsNotAResume() {
        XCTAssertFalse(isUnderWay(phase: .failed("The Mac refused the connection.")))
    }

    func testTheUsersOwnDoingOutranksEverything() {
        XCTAssertFalse(isUnderWay(userEndedDeliberately: true, isReconnecting: true))
        XCTAssertFalse(isUnderWay(userEndedDeliberately: true, phase: .connecting))
    }
}
