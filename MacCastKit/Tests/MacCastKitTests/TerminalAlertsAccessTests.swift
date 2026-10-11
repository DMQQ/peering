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
        XCTAssertTrue(TerminalAlertsAccess.canNotify(access: .known(.pro)))
    }

    func testFreePlanIsToldOnTheHomeNetwork() {
        XCTAssertTrue(TerminalAlertsAccess.allowsBanner(planIncluded: false, onLAN: true))
    }

    func testFreePlanIsNotToldOverTheRelay() {
        XCTAssertFalse(TerminalAlertsAccess.allowsBanner(planIncluded: false, onLAN: false))
    }

    func testPaidPlanIsToldOnAnyPath() {
        XCTAssertTrue(TerminalAlertsAccess.allowsBanner(planIncluded: true, onLAN: false))
    }
}
