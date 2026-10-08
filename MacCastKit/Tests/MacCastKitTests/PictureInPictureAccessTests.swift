import XCTest
@testable import MacCastKit

final class PictureInPictureAccessTests: XCTestCase {
    func testUnreadPlanCannotArmAutomaticPictureInPicture() {
        XCTAssertFalse(PictureInPictureAccess.canArm(access: .unknown))
    }

    func testFreePlanCannotArmAutomaticPictureInPicture() {
        XCTAssertFalse(PictureInPictureAccess.canArm(access: .known(.free)))
    }

    func testPaidPlanCanArmAutomaticPictureInPicture() {
        XCTAssertTrue(PictureInPictureAccess.canArm(access: .known(.relay)))
    }

    func testFreePlanCannotStartPictureInPicture() {
        XCTAssertFalse(PictureInPictureAccess.canStart(isOnPlan: false))
    }

    func testPaidPlanCanStartPictureInPicture() {
        XCTAssertTrue(PictureInPictureAccess.canStart(isOnPlan: true))
    }
}
