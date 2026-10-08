import XCTest
@testable import MacCastKit

final class BackgroundSessionExpiryTests: XCTestCase {
    func testCurrentBackgroundAssertionMayEndAnOpenSession() {
        XCTAssertTrue(BackgroundSessionExpiry.shouldEndSession(
            assertionIsActive: true,
            appIsBackground: true,
            hasOpenSession: true,
            pictureInPictureIsActive: false
        ))
    }

    func testCallbackQueuedBeforeForegroundCannotEndTheRestoredSession() {
        XCTAssertFalse(BackgroundSessionExpiry.shouldEndSession(
            assertionIsActive: false,
            appIsBackground: false,
            hasOpenSession: true,
            pictureInPictureIsActive: false
        ))
    }

    func testCallbackDuringForegroundTransitionCannotEndTheSession() {
        XCTAssertFalse(BackgroundSessionExpiry.shouldEndSession(
            assertionIsActive: true,
            appIsBackground: false,
            hasOpenSession: true,
            pictureInPictureIsActive: false
        ))
    }

    func testThereIsNothingToEndWithoutAnOpenSession() {
        XCTAssertFalse(BackgroundSessionExpiry.shouldEndSession(
            assertionIsActive: true,
            appIsBackground: true,
            hasOpenSession: false,
            pictureInPictureIsActive: false
        ))
    }

    func testPictureInPictureOwnsTheBackgroundSessionAfterTheAssertionExpires() {
        XCTAssertFalse(BackgroundSessionExpiry.shouldEndSession(
            assertionIsActive: true,
            appIsBackground: true,
            hasOpenSession: true,
            pictureInPictureIsActive: true
        ))
    }
}
