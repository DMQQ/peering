import Testing
@testable import PeeringKit

@Suite("One device at a time")
struct SingleDevicePolicyTests {
    @Test func anEmptyMacAdmitsAnyone() {
        #expect(SingleDevicePolicy.decide(newcomer: "b", others: []) == .admit(evicting: []))
    }

    @Test func aPresentPhoneTurnsASecondDeviceAway() {
        let others = [SingleDevicePolicy.Peer(clientID: "a", silence: 1)]
        #expect(SingleDevicePolicy.decide(newcomer: "b", others: others) == .refuse)
    }

    @Test func aSilentPhoneIsReplaced() {
        let others = [SingleDevicePolicy.Peer(clientID: "a", silence: 25)]
        #expect(SingleDevicePolicy.decide(newcomer: "b", others: others) == .admit(evicting: ["a"]))
    }

    @Test func theSamePhoneOnAnotherRouteIsNotARival() {
        let others = [SingleDevicePolicy.Peer(clientID: "a", silence: 0)]
        #expect(SingleDevicePolicy.decide(newcomer: "a", others: others) == .admit(evicting: []))
    }

    @Test func onePresentPhoneAmongStaleOnesStillRefuses() {
        let others = [SingleDevicePolicy.Peer(clientID: "a", silence: 40), SingleDevicePolicy.Peer(clientID: "c", silence: 2)]
        #expect(SingleDevicePolicy.decide(newcomer: "b", others: others) == .refuse)
    }
}
