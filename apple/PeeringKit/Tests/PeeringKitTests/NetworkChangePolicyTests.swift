import XCTest
@testable import PeeringKit

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

    /// Asking is not acting: a policy that spent the change on being asked would leave nothing for the drop that follows.
    func testAskingWithoutDiallingLeavesTheChangeUnspent() {
        var policy = NetworkChangePolicy()
        let cellular = path(true, [.cellular])

        XCTAssertTrue(policy.shouldDialNow(for: cellular), "asked while nothing was resuming")
        XCTAssertTrue(policy.shouldDialNow(for: cellular), "and still news when a Mac needs it")
    }

    /// Holding on to the dialled-on network would make the return look like no change.
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
