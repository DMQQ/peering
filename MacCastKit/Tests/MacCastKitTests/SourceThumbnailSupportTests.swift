import XCTest
@testable import MacCastKit

/// The rule for asking a Mac to photograph its running applications.
///
/// The same shape as ``MosaicSupportTests`` and for the same reason — a request an older Mac
/// cannot decode ends the session rather than degrading it — but the moment it lands on is
/// easier to reach than the mosaic's: this one is sent when somebody opens the Apps panel, which
/// is an ordinary thing to do.
final class SourceThumbnailSupportTests: XCTestCase {
    func testAMacThatHasNotHeardTheQuestionIsNotAsked() {
        // `nil` is a Mac built before the field existed. Reading it as "not false, so probably
        // fine" would send a command that Mac cannot decode, and the session would end for
        // asking to see a thumbnail.
        XCTAssertFalse(SourceThumbnailSupport.maySend(hostDeclared: nil))
    }

    func testAMacThatRefusedIsNotAsked() {
        XCTAssertFalse(SourceThumbnailSupport.maySend(hostDeclared: false))
    }

    func testAMacThatSaidYesIsAsked() {
        XCTAssertTrue(SourceThumbnailSupport.maySend(hostDeclared: true))
    }
}
