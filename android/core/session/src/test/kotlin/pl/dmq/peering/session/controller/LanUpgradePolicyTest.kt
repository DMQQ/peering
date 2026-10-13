package pl.dmq.peering.session.controller

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.history.SessionRecord.Path
import pl.dmq.peering.session.testing.FakeClock

class LanUpgradePolicyTest {
    @Test
    fun aRelayedOrPunchedSessionMovesWhenTheMacIsOnTheLan() {
        assertTrue(LanUpgradePolicy.shouldUpgrade(Path.RELAY, macVisibleOnLan = true, secondsSinceLastAttempt = null))
        assertTrue(LanUpgradePolicy.shouldUpgrade(Path.DIRECT, macVisibleOnLan = true, secondsSinceLastAttempt = null))
    }

    @Test
    fun aSessionAlreadyOnTheLanStays() {
        assertFalse(LanUpgradePolicy.shouldUpgrade(Path.LAN, macVisibleOnLan = true, secondsSinceLastAttempt = null))
    }

    @Test
    fun aMacNobodyCanSeeIsNotDialled() {
        assertFalse(LanUpgradePolicy.shouldUpgrade(Path.RELAY, macVisibleOnLan = false, secondsSinceLastAttempt = null))
    }

    @Test
    fun aFailedAttemptIsNotRepeatedAtOnce() {
        assertFalse(LanUpgradePolicy.shouldUpgrade(Path.RELAY, macVisibleOnLan = true, secondsSinceLastAttempt = 10.0))
        assertTrue(LanUpgradePolicy.shouldUpgrade(Path.RELAY, macVisibleOnLan = true, secondsSinceLastAttempt = 90.0))
    }

    @Test
    fun attemptsAreCountedPerMacAcrossSessions() {
        val clock = FakeClock()
        val policy = LanUpgradePolicy(clock)

        assertTrue(policy.begin("mac-a", Path.RELAY))
        clock.advance(30.0)
        assertFalse(policy.begin("mac-a", Path.DIRECT))
        assertTrue(policy.begin("mac-b", Path.RELAY))
        clock.advance(60.0)
        assertTrue(policy.begin("mac-a", Path.RELAY))
    }
}
