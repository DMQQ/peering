//
//  PlanAccessTests.swift
//  MacCastKitTests
//

import XCTest
@testable import MacCastKit

/// The plan map is also stated in the paywall, wiki/PLANS-AND-FEATURES.md and the site; this second copy fails a build when they drift.
/// A plan not yet read locks nothing (the no-flash rule).
final class PlanAccessTests: XCTestCase {

    /// The map as the cards and the site state it: cheapest plan including each capability.
    private static let expected: [PlanCapability: RelayPlan] = [
        .extraMacs: .relay,
        .concurrentSessions: .pro,
        .macSound: .relay,
        .pictureInPicture: .relay,
        .fileTransfer: .relay,
        .clipboardHistory: .relay,
        .terminalAlerts: .relay,
        .shellTabs: .pro,
        .macros: .pro,
        .highBitrate: .pro,
        .mosaic: .pro,
        .virtualDisplays: .pro,
    ]

    func testTheMapSaysWhatTheCardsAndTheSiteSay() {
        for (capability, minimum) in Self.expected {
            XCTAssertEqual(
                capability.minimumPlan, minimum,
                "\(capability.rawValue) needs \(minimum.rawValue) on the cards, the site and the plans document"
            )
        }
    }

    /// A capability on the map but not in the table would be gated without agreement.
    func testNothingIsGatedThatIsNotOnTheList() {
        XCTAssertEqual(
            Set(PlanCapability.allCases), Set(Self.expected.keys),
            "a capability was added or removed without the paywall, the site and the plans document being changed with it"
        )
    }

    /// Free includes nothing on the map.
    func testFreeIncludesNoneOfTheGatedFeatures() {
        for capability in PlanCapability.allCases {
            XCTAssertFalse(
                RelayPlan.free.includes(capability),
                "\(capability.rawValue) is free, so it should not be on the map or should be moved to free"
            )
        }
    }

    /// Relay must not pick up the tabs and macros that sell Pro.
    func testRelayAddsTheRemoteWorkingSetAndNothingAboveIt() {
        for capability in PlanCapability.allCases where capability.minimumPlan == .relay {
            XCTAssertTrue(RelayPlan.relay.includes(capability))
        }

        XCTAssertFalse(RelayPlan.relay.includes(.shellTabs))
        XCTAssertFalse(RelayPlan.relay.includes(.macros))
    }

    func testProAddsTheSecondShellAndVirtualDisplays() {
        XCTAssertTrue(RelayPlan.pro.includes(.shellTabs))
        XCTAssertTrue(RelayPlan.pro.includes(.virtualDisplays))
        XCTAssertFalse(RelayPlan.relay.includes(.shellTabs))
        XCTAssertFalse(RelayPlan.relay.includes(.virtualDisplays))
    }

    func testProIncludesEverythingTheMapKnowsAbout() {
        for capability in PlanCapability.allCases {
            XCTAssertTrue(
                RelayPlan.pro.includes(capability),
                "\(capability.rawValue) is locked on Pro, which means the ladder has a rung above the top one"
            )
        }
    }

    /// StoreKit is read over an await, so a paying subscriber must not see a locked app while the plan is unknown.
    func testAnUnreadPlanLocksNothing() {
        let unknown = PlanAccess.unknown
        for capability in PlanCapability.allCases {
            XCTAssertTrue(
                unknown.includes(capability),
                "\(capability.rawValue) is locked before the App Store has answered, which is the flash on launch"
            )
        }
        XCTAssertNil(unknown.plan, "an unanswered plan is not a plan, and must not be read as one")
    }

    /// Unknown is not free: gating on plan == .free would lock everyone while the entitlement loads.
    func testAnUnreadPlanIsNotTheFreePlan() {
        XCTAssertNotEqual(PlanAccess.unknown, PlanAccess.known(.free))
        XCTAssertTrue(PlanAccess.unknown.includes(.macros))
        XCTAssertFalse(PlanAccess.known(.free).includes(.macros))
    }

    /// The relay allowance is a free-plan limit; an unanswered entitlement must not draw the meter.
    func testOnlyAKnownFreePlanShowsTheRelayAllowance() {
        XCTAssertFalse(PlanAccess.unknown.showsRelayAllowance)
        XCTAssertTrue(PlanAccess.known(.free).showsRelayAllowance)
        XCTAssertFalse(PlanAccess.known(.relay).showsRelayAllowance)
        XCTAssertFalse(PlanAccess.known(.pro).showsRelayAllowance)
    }

    func testTheLadderIsTheOrderOfAllCases() {
        XCTAssertLessThan(RelayPlan.free, RelayPlan.relay)
        XCTAssertLessThan(RelayPlan.relay, RelayPlan.pro)
        XCTAssertFalse(RelayPlan.pro < RelayPlan.pro, "a plan is not below itself")
    }

    /// Every capability has a unique name, since a refused gate shows it.
    func testEveryCapabilityNamesItselfOnce() {
        let names = PlanCapability.allCases.map(\.name)
        XCTAssertFalse(names.contains(where: \.isEmpty))
        XCTAssertEqual(Set(names).count, names.count, "two capabilities share a name")
    }

    func testThePlanNamesAreTheWordsOnTheCards() {
        XCTAssertEqual(RelayPlan.free.name, "Free")
        XCTAssertEqual(RelayPlan.relay.name, "Relay")
        XCTAssertEqual(RelayPlan.pro.name, "Pro")
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
