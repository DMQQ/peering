import XCTest
@testable import MacCastKit

/// The compatibility rule and resource ceiling for displays the phone asks the Mac to make.
final class VirtualDisplayManagementSupportTests: XCTestCase {
    func testAMacThatHasNotHeardTheQuestionIsNotAsked() {
        XCTAssertFalse(VirtualDisplayManagementSupport.maySend(hostDeclared: nil))
    }

    func testAMacThatRefusedIsNotAsked() {
        XCTAssertFalse(VirtualDisplayManagementSupport.maySend(hostDeclared: false))
    }

    func testAMacThatSaidYesIsAsked() {
        XCTAssertTrue(VirtualDisplayManagementSupport.maySend(hostDeclared: true))
    }

    func testTheClientAndHostShareTheThreeDisplayCeiling() {
        XCTAssertEqual(VirtualDisplayManagementSupport.maximumManagedDisplayCount, 3)
    }
}
