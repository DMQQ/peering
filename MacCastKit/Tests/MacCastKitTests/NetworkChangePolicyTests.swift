import XCTest
@testable import MacCastKit

/// The rule that decides when a phone changing network is worth dialling now for.
final class NetworkChangePolicyTests: XCTestCase {
    private func path(
        _ satisfied: Bool,
        _ interfaces: Set<NetworkPathSnapshot.Interface>
    ) -> NetworkPathSnapshot {
        NetworkPathSnapshot(isSatisfied: satisfied, interfaces: interfaces)
    }

    func testAUsablePathIsWorthDiallingOn() {
        var policy = NetworkChangePolicy()
        XCTAssertTrue(policy.shouldDialNow(for: path(true, [.cellular])))
    }

    /// A path that is not usable has nothing to dial over, and an attempt made on it is a rung of
    /// the ladder spent to fail.
    func testAPathWithNoNetworkIsNeverWorthDiallingOn() {
        var policy = NetworkChangePolicy()
        XCTAssertFalse(policy.shouldDialNow(for: path(false, [])))
        XCTAssertFalse(policy.shouldDialNow(for: path(false, [.wifi])))
    }

    func testThePathADialWasMadeOnIsNotNewsAgain() {
        var policy = NetworkChangePolicy()
        let wifi = path(true, [.wifi])

        XCTAssertTrue(policy.shouldDialNow(for: wifi))
        policy.noteDialled(on: wifi)
        XCTAssertFalse(policy.shouldDialNow(for: wifi))
    }

    /// **Asking is not acting, and this is the difference.** The app asks about the network at
    /// moments when it has nothing to dial, because a change is only worth acting on when a Mac is
    /// being put back. A policy that spent the change on being asked would leave the drop that
    /// arrives afterwards nothing to find, which on a relay session is the ordinary case: the
    /// socket hands on for as long as the silence watchdog allows, and the network moved seconds
    /// before the drop was noticed.
    func testAskingWithoutDiallingLeavesTheChangeUnspent() {
        var policy = NetworkChangePolicy()
        let cellular = path(true, [.cellular])

        XCTAssertTrue(policy.shouldDialNow(for: cellular), "asked while nothing was resuming")
        XCTAssertTrue(policy.shouldDialNow(for: cellular), "and still news when a Mac needs it")
    }

    /// The ordinary shape of a switch: the network goes away and comes back reporting what it had
    /// before. Holding on to what was dialled on would make the return look like no change, and the
    /// app would sleep out its backoff beside a network that is already up.
    func testANetworkThatComesBackIsNewsAgain() {
        var policy = NetworkChangePolicy()
        let wifi = path(true, [.wifi])

        policy.noteDialled(on: wifi)
        XCTAssertFalse(policy.shouldDialNow(for: path(false, [.wifi])), "gone")
        XCTAssertTrue(policy.shouldDialNow(for: wifi), "and back, which is a new path to dial on")
    }

    func testMovingBetweenInterfacesIsNews() {
        var policy = NetworkChangePolicy()
        policy.noteDialled(on: path(true, [.wifi]))

        XCTAssertTrue(policy.shouldDialNow(for: path(true, [.cellular])))
        XCTAssertTrue(policy.shouldDialNow(for: path(true, [.wifi, .cellular])))
    }
}
