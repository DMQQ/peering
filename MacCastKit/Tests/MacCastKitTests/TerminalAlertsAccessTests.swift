import XCTest
@testable import MacCastKit

final class TerminalAlertsAccessTests: XCTestCase {
    func testUnreadPlanCannotBeToldAboutATerminal() {
        XCTAssertFalse(TerminalAlertsAccess.canNotify(access: .unknown))
    }

    func testFreePlanCannotBeToldAboutATerminal() {
        XCTAssertFalse(TerminalAlertsAccess.canNotify(access: .known(.free)))
    }

    func testEveryPaidPlanCanBeToldAboutATerminal() {
        XCTAssertTrue(TerminalAlertsAccess.canNotify(access: .known(.relay)))
        XCTAssertTrue(TerminalAlertsAccess.canNotify(access: .known(.plus)))
        XCTAssertTrue(TerminalAlertsAccess.canNotify(access: .known(.pro)))
    }
}
