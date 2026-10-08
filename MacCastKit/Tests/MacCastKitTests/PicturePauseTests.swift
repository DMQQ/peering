//
//  PicturePauseTests.swift
//  MacCastKitTests
//

import XCTest
@testable import MacCastKit

/// supportsVideoPause is optional: nil (an old Mac) must not be read as permission, or an unknown command breaks the session.
final class PicturePauseTests: XCTestCase {

    func testAMacThatDeclaredTheCapabilityMayBeAsked() {
        XCTAssertTrue(PicturePause.mayAsk(hostDeclared: true))
    }

    /// An old Mac sends no answer, and no answer is not permission.
    func testAMacThatNeverHeardTheQuestionMayNotBeAsked() {
        XCTAssertFalse(PicturePause.mayAsk(hostDeclared: nil))
    }

    func testAMacThatDeclinedMayNotBeAsked() {
        XCTAssertFalse(PicturePause.mayAsk(hostDeclared: false))
    }

    /// Three states, not a Bool: a refactor collapsing them should fail here.
    func testNotKnowingIsDistinguishedFromRefusing() {
        XCTAssertNotEqual(
            PicturePause.mayAsk(hostDeclared: nil),
            PicturePause.mayAsk(hostDeclared: true)
        )
    }
}
