import XCTest
@testable import MacCastKit

/// The rule for asking a Mac for a mosaic, which is the one place a wrong answer ends a session
/// rather than degrading one: the request is a capture source an older Mac cannot decode.
final class MosaicSupportTests: XCTestCase {
    func testAMacThatHasNotHeardTheQuestionIsNotAsked() {
        // `nil` is a Mac built before the field existed, and reading it as "not false, so
        // probably fine" is the natural mistake. Here it costs the session.
        XCTAssertFalse(MosaicSupport.maySend(hostDeclared: nil))
    }

    func testAMacThatRefusedIsNotAsked() {
        XCTAssertFalse(MosaicSupport.maySend(hostDeclared: false))
    }

    func testAMacThatSaidYesIsAsked() {
        XCTAssertTrue(MosaicSupport.maySend(hostDeclared: true))
    }
}
