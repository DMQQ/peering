import XCTest
@testable import MacCastKit

/// Same rule as ``MosaicSupportTests``: an undecodable request ends the session.
final class SourceThumbnailSupportTests: XCTestCase {
    func testAMacThatHasNotHeardTheQuestionIsNotAsked() {
        // nil is an older Mac; reading it as "not false" sends a command it cannot decode.
        XCTAssertFalse(SourceThumbnailSupport.maySend(hostDeclared: nil))
    }

    func testAMacThatRefusedIsNotAsked() {
        XCTAssertFalse(SourceThumbnailSupport.maySend(hostDeclared: false))
    }

    func testAMacThatSaidYesIsAsked() {
        XCTAssertTrue(SourceThumbnailSupport.maySend(hostDeclared: true))
    }
}
