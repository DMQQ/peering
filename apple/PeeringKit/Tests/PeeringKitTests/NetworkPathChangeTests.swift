import Testing
@testable import PeeringKit

@Suite("Network path changes")
struct NetworkPathChangeTests {
    @Test func theFirstUpdateOnlyReportsWhereThingsAre() {
        var change = NetworkPathChange()
        let result1 = change.update(isSatisfied: true, interfaceNames: ["en0"])
        #expect(!result1)
    }

    @Test func aSameUpdateIsNotAChange() {
        var change = NetworkPathChange()
        _ = change.update(isSatisfied: true, interfaceNames: ["en0"])
        let result2 = change.update(isSatisfied: true, interfaceNames: ["en0"])
        #expect(!result2)
    }

    @Test func aVPNInterfaceAppearingOrLeavingIsAChange() {
        var change = NetworkPathChange()
        _ = change.update(isSatisfied: true, interfaceNames: ["en0", "utun4"])
        let result3 = change.update(isSatisfied: true, interfaceNames: ["en0"])
        #expect(result3)
        let result4 = change.update(isSatisfied: true, interfaceNames: ["utun4", "en0"])
        #expect(result4)
    }

    @Test func interfaceOrderIsNotAChange() {
        var change = NetworkPathChange()
        _ = change.update(isSatisfied: true, interfaceNames: ["en0", "utun4"])
        let result5 = change.update(isSatisfied: true, interfaceNames: ["utun4", "en0"])
        #expect(!result5)
    }

    @Test func aPathThatWasLostAndCameBackOnTheSameInterfacesIsAChange() {
        var change = NetworkPathChange()
        _ = change.update(isSatisfied: true, interfaceNames: ["en0"])
        let result6 = change.update(isSatisfied: false, interfaceNames: [])
        #expect(!result6)
        let result7 = change.update(isSatisfied: true, interfaceNames: ["en0"])
        #expect(result7)
        let result8 = change.update(isSatisfied: true, interfaceNames: ["en0"])
        #expect(!result8)
    }

    @Test func aPathLostBeforeAnythingWasSeenIsNotAChange() {
        var change = NetworkPathChange()
        let result9 = change.update(isSatisfied: false, interfaceNames: [])
        #expect(!result9)
        let result10 = change.update(isSatisfied: true, interfaceNames: ["en0"])
        #expect(!result10)
    }
}
