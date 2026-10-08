import XCTest
@testable import MacCastKit

final class MosaicSupportTests: XCTestCase {
    func testAMacThatHasNotHeardTheQuestionIsNotAsked() {
        // nil is a Mac that predates the field; reading it as "not false" costs the session.
        XCTAssertFalse(MosaicSupport.maySend(hostDeclared: nil))
    }

    func testAMacThatRefusedIsNotAsked() {
        XCTAssertFalse(MosaicSupport.maySend(hostDeclared: false))
    }

    func testAMacThatSaidYesIsAsked() {
        XCTAssertTrue(MosaicSupport.maySend(hostDeclared: true))
    }
}
