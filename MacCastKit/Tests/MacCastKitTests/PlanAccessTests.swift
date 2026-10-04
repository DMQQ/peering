//
//  PlanAccessTests.swift
//  MacCastKitTests
//

import XCTest
@testable import MacCastKit

/// The map of what each plan includes, tested where it can be run.
///
/// **The map is stated in four places and this is the only pair of them that can disagree out
/// loud.** The app's paywall cards, its "Everything included" list, `PLANS-AND-FEATURES.md` and
/// `Relay/site/index.html` all say what each plan adds, and three of them are prose that no
/// compiler reads. A row that moves on one screen and not the other is the failure this whole
/// arrangement exists to prevent, and from inside the app it looks exactly like everything working.
///
/// So the table is written out a second time below, on purpose, in the one form that fails a build
/// when the two stop matching. Moving a capability to another rung is not an edit to this file that
/// can be made by accident: it takes a deliberate change here as well, and the person making it is
/// standing in front of the prose they now owe the same change to.
///
/// The rest of this file is the rule the owner's no-flash requirement rests on: a plan that has not
/// been read yet locks nothing.
final class PlanAccessTests: XCTestCase {

    /// The map, as the cards and the site state it.
    ///
    /// Cheapest plan that includes each capability, and every one the app is allowed to gate. A
    /// capability missing from this table fails ``testNothingIsGatedThatIsNotOnTheList``; a
    /// capability on this table that the app does not actually honour fails nothing here, which is
    /// why the rows in the maps are checked against the controls by hand as well.
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

    /// The row above, as a table, because that is how three of the four copies of this map are
    /// written.
    ///
    /// Written as plans rather than as capabilities so the failure message names the plan a feature
    /// moved to, which is the sentence somebody has to go and check the paywall against.
    func testTheMapSaysWhatTheCardsAndTheSiteSay() {
        for (capability, minimum) in Self.expected {
            XCTAssertEqual(
                capability.minimumPlan, minimum,
                "\(capability.rawValue) needs \(minimum.rawValue) on the cards, the site and the plans document"
            )
        }
    }

    /// **The other direction, and the one that matters more.** A capability that is on the map and
    /// not in the table above would be gated without anybody having agreed to gate it.
    func testNothingIsGatedThatIsNotOnTheList() {
        XCTAssertEqual(
            Set(PlanCapability.allCases), Set(Self.expected.keys),
            "a capability was added or removed without the paywall, the site and the plans document being changed with it"
        )
    }

    /// The free plan includes nothing on the map. Everything free is free by not being a case of
    /// ``PlanCapability`` at all, so this is the guard on the eleven that are.
    func testFreeIncludesNoneOfTheGatedFeatures() {
        for capability in PlanCapability.allCases {
            XCTAssertFalse(
                RelayPlan.free.includes(capability),
                "\(capability.rawValue) is free, so it should not be on the map or should be moved to free"
            )
        }
    }

    /// Relay is the remote working set. It is not the clock going away and not the toolbox: the two
    /// rungs above it are the ones that sell on tabs and macros, and this is what stops one of them
    /// drifting down into it.
    func testRelayAddsTheRemoteWorkingSetAndNothingAboveIt() {
        for capability in PlanCapability.allCases where capability.minimumPlan == .relay {
            XCTAssertTrue(RelayPlan.relay.includes(capability))
        }

        XCTAssertFalse(RelayPlan.relay.includes(.shellTabs))
        XCTAssertFalse(RelayPlan.relay.includes(.macros))
    }

    /// Pro carries the shell tabs and the virtual displays, and Relay does not.
    func testProAddsTheSecondShellAndVirtualDisplays() {
        XCTAssertTrue(RelayPlan.pro.includes(.shellTabs))
        XCTAssertTrue(RelayPlan.pro.includes(.virtualDisplays))
        XCTAssertFalse(RelayPlan.relay.includes(.shellTabs))
        XCTAssertFalse(RelayPlan.relay.includes(.virtualDisplays))
    }

    /// The top rung leaves nothing on the map locked, so a Pro subscriber can never be shown a
    /// padlock.
    func testProIncludesEverythingTheMapKnowsAbout() {
        for capability in PlanCapability.allCases {
            XCTAssertTrue(
                RelayPlan.pro.includes(capability),
                "\(capability.rawValue) is locked on Pro, which means the ladder has a rung above the top one"
            )
        }
    }

    /// **The rule the whole of `PlanAccess` exists for.** The entitlement is read from StoreKit over
    /// an `await`, so there is a moment on every launch with no answer, and a paying subscriber must
    /// not spend that moment looking at a locked app. Nothing on the map may be locked while the
    /// plan is unknown.
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

    /// And the other half of that: unknown is not free.
    ///
    /// A gate written as `access.plan == .free` rather than `!access.includes(...)` would read an
    /// unanswered entitlement as the free plan and lock the app for everybody, which is the same
    /// bug arriving through the other door.
    func testAnUnreadPlanIsNotTheFreePlan() {
        XCTAssertNotEqual(PlanAccess.unknown, PlanAccess.known(.free))
        XCTAssertTrue(PlanAccess.unknown.includes(.macros))
        XCTAssertFalse(PlanAccess.known(.free).includes(.macros))
    }

    /// The relay allowance is a free-plan limit, not a feature of the Sessions screen for every
    /// subscriber. Paid plans have no allowance to inspect, and an unanswered entitlement must
    /// not briefly draw the free user's meter while StoreKit is still loading.
    func testOnlyAKnownFreePlanShowsTheRelayAllowance() {
        XCTAssertFalse(PlanAccess.unknown.showsRelayAllowance)
        XCTAssertTrue(PlanAccess.known(.free).showsRelayAllowance)
        XCTAssertFalse(PlanAccess.known(.relay).showsRelayAllowance)
        XCTAssertFalse(PlanAccess.known(.pro).showsRelayAllowance)
    }

    /// The ladder is `allCases` order, which is what the paywall draws its cards in and what the
    /// app reads to pick the best of several live subscriptions.
    func testTheLadderIsTheOrderOfAllCases() {
        XCTAssertLessThan(RelayPlan.free, RelayPlan.relay)
        XCTAssertLessThan(RelayPlan.relay, RelayPlan.pro)
        XCTAssertFalse(RelayPlan.pro < RelayPlan.pro, "a plan is not below itself")
    }

    /// Every capability carries a name, and no two of them carry the same one.
    ///
    /// The name is what a refused gate says it refused, so a blank or a duplicate is a purchase
    /// screen telling the user that they just tapped "Picture in Picture" when they tapped the
    /// sound switch.
    func testEveryCapabilityNamesItselfOnce() {
        let names = PlanCapability.allCases.map(\.name)
        XCTAssertFalse(names.contains(where: \.isEmpty))
        XCTAssertEqual(Set(names).count, names.count, "two capabilities share a name")
    }

    /// The plan names are the words on the cards, because a lock promising Pro has to use
    /// the spelling the card selling it does.
    func testThePlanNamesAreTheWordsOnTheCards() {
        XCTAssertEqual(RelayPlan.free.name, "Free")
        XCTAssertEqual(RelayPlan.relay.name, "Relay")
        XCTAssertEqual(RelayPlan.pro.name, "Pro")
    }

    /// These values feed the paywall, onboarding and Sessions meter. Keeping the number and its
    /// spelling in one test prevents a copy-only edit from promising a different allowance than
    /// the relay enforces.
    func testThePlanAllowancesMatchTheProductPromise() {
        XCTAssertEqual(RelayPlan.free.allowanceSeconds, 60 * 60)
        XCTAssertEqual(RelayPlan.free.allowanceSpelling, "one hour")

        for plan in [RelayPlan.relay, .pro] {
            XCTAssertNil(plan.allowanceSeconds, "\(plan.name) should be unlimited")
            XCTAssertEqual(plan.allowanceSpelling, "unlimited relay")
        }
    }
}
