//
//  PicturePauseTests.swift
//  MacCastKitTests
//

import XCTest
@testable import MacCastKit

/// When a client may ask a Mac to stop sending the picture.
///
/// The rule is one comparison and it is written out in full because the mistake it prevents is
/// the natural one: `supportsVideoPause` is optional, and `nil` read as "not false, so probably
/// fine" would send an unknown command to a Mac that has never heard of it, which is a decode
/// failure in the middle of a session. That costs a working session on an old Mac to save some
/// bandwidth on a new one, and it only shows up for a user with two Macs of different vintages.
final class PicturePauseTests: XCTestCase {

    /// A Mac that has heard the question and said yes.
    func testAMacThatDeclaredTheCapabilityMayBeAsked() {
        XCTAssertTrue(PicturePause.mayAsk(hostDeclared: true))
    }

    /// **The one that matters.** A Mac built before the field existed sends a hello with no
    /// answer in it, and no answer is not permission.
    func testAMacThatNeverHeardTheQuestionMayNotBeAsked() {
        XCTAssertFalse(PicturePause.mayAsk(hostDeclared: nil))
    }

    /// A Mac that knows about the command and declined it.
    func testAMacThatDeclinedMayNotBeAsked() {
        XCTAssertFalse(PicturePause.mayAsk(hostDeclared: false))
    }

    /// The three states do not collapse into two: this is the whole reason the decision is not a
    /// `Bool` on the hello, and a future refactor that makes it one should fail here.
    func testNotKnowingIsDistinguishedFromRefusing() {
        XCTAssertNotEqual(
            PicturePause.mayAsk(hostDeclared: nil),
            PicturePause.mayAsk(hostDeclared: true)
        )
    }
}
