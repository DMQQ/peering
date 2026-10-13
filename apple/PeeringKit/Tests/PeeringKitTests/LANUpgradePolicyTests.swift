import Testing
@testable import PeeringKit

struct LANUpgradePolicyTests {
    @Test func aRelayedSessionMovesWhenTheMacIsOnTheLan() {
        #expect(LANUpgradePolicy.shouldUpgrade(path: .relay, macVisibleOnLAN: true, secondsSinceLastAttempt: nil))
        #expect(LANUpgradePolicy.shouldUpgrade(path: .direct, macVisibleOnLAN: true, secondsSinceLastAttempt: nil))
    }

    @Test func aSessionAlreadyOnTheLanStays() {
        #expect(!LANUpgradePolicy.shouldUpgrade(path: .lan, macVisibleOnLAN: true, secondsSinceLastAttempt: nil))
        #expect(!LANUpgradePolicy.shouldUpgrade(path: nil, macVisibleOnLAN: true, secondsSinceLastAttempt: nil))
    }

    @Test func aMacNobodyCanSeeIsNotDialled() {
        #expect(!LANUpgradePolicy.shouldUpgrade(path: .relay, macVisibleOnLAN: false, secondsSinceLastAttempt: nil))
    }

    @Test func aFailedAttemptIsNotRepeatedAtOnce() {
        #expect(!LANUpgradePolicy.shouldUpgrade(path: .relay, macVisibleOnLAN: true, secondsSinceLastAttempt: 10))
        #expect(LANUpgradePolicy.shouldUpgrade(path: .relay, macVisibleOnLAN: true, secondsSinceLastAttempt: 90))
    }
}
