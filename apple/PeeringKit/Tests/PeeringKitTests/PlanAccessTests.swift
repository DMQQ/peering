//
//  PlanAccessTests.swift
//  PeeringKitTests
//

import XCTest
@testable import PeeringKit

final class PlanAccessTests: XCTestCase {

    /// StoreKit is read over an await, so an unanswered plan must not be read as a plan.
    func testAnUnreadPlanIsNotAPlan() {
        XCTAssertNil(PlanAccess.unknown.plan)
    }

    /// Unknown is not free: showing the meter to everyone while the entitlement loads would flash it at paying users.
    func testAnUnreadPlanIsNotTheFreePlan() {
        XCTAssertNotEqual(PlanAccess.unknown, PlanAccess.known(.free))
    }

    /// The relay allowance is a free-plan limit; an unanswered entitlement must not draw the meter.
    func testOnlyAKnownFreePlanShowsTheRelayAllowance() {
        XCTAssertFalse(PlanAccess.unknown.showsRelayAllowance)
        XCTAssertTrue(PlanAccess.known(.free).showsRelayAllowance)
        XCTAssertFalse(PlanAccess.known(.relay).showsRelayAllowance)
        XCTAssertFalse(PlanAccess.known(.pro).showsRelayAllowance)
    }

    /// Pins the allowance number and its spelling against the relay's limit.
    func testThePlanAllowancesMatchTheProductPromise() {
        XCTAssertEqual(RelayPlan.free.allowanceSeconds, 30 * 60)
        XCTAssertEqual(RelayPlan.free.allowanceSpelling, "30 minutes")

        for plan in [RelayPlan.relay, .pro] {
            XCTAssertNil(plan.allowanceSeconds, "\(plan.name) should be unlimited")
            XCTAssertEqual(plan.allowanceSpelling, "unlimited relay")
        }
    }
}
