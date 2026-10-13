package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.feature.paywall.RelayAllowance

class RelayMinutesTest {
    @Test
    fun minutesLeftAreWholeMinutesOfTheFreeDay() {
        assertEquals(28, relayMinutesLeft(RelayAllowance(usedSeconds = 90, paid = false)))
    }

    @Test
    fun aPaidPlanHasNoMinutesToCount() {
        assertNull(relayMinutesLeft(RelayAllowance(usedSeconds = 9_999, paid = true)))
    }
}
