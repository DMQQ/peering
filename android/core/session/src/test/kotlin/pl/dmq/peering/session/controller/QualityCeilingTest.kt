package pl.dmq.peering.session.controller

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.wire.QualityTier

class QualityCeilingTest {
    @Test
    fun aRelayedSessionWithoutUnlimitedTimeIsHeldToMedium() {
        assertEquals(QualityTier.MEDIUM, QualityCeiling.of(SessionRecord.Path.RELAY, unlimitedRelay = false))
    }

    @Test
    fun unlimitedRelayTimeLiftsTheCap() {
        assertEquals(QualityTier.HIGH, QualityCeiling.of(SessionRecord.Path.RELAY, unlimitedRelay = true))
    }

    @Test
    fun localAndDirectSessionsAreNeverCapped() {
        assertEquals(QualityTier.HIGH, QualityCeiling.of(SessionRecord.Path.LAN, unlimitedRelay = false))
        assertEquals(QualityTier.HIGH, QualityCeiling.of(SessionRecord.Path.DIRECT, unlimitedRelay = false))
    }
}
