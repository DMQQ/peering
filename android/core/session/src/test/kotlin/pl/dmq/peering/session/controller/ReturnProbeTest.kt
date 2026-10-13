package pl.dmq.peering.session.controller

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.connection.LivenessMonitor
import pl.dmq.peering.session.ports.Clock

class ReturnProbeTest {
    @Test
    fun aMoveWhileAwayProbesOnceOnReturn() {
        val probe = ReturnProbe()
        probe.networkMoved(backgrounded = true)

        assertTrue(probe.onReturn())
        assertFalse(probe.onReturn())
    }

    @Test
    fun aMoveWhileOnScreenNeedsNoProbe() {
        val probe = ReturnProbe()
        probe.networkMoved(backgrounded = false)

        assertFalse(probe.onReturn())
    }

    @Test
    fun returningWithoutAMoveDoesNotProbe() {
        assertFalse(ReturnProbe().onReturn())
    }

    @Test
    fun theSilenceCountedFromReturnIsJudgedByTheThreeSecondLimit() {
        val liveness = LivenessMonitor(object : Clock {
            override fun monotonicSeconds() = 0.0
            override fun unixSeconds() = 0L
        })
        liveness.resetSilence()

        assertFalse(liveness.isSilent(nowSeconds = 3.0, limitSeconds = SilencePolicy.limitSeconds(backgrounded = false)))
        assertTrue(liveness.isSilent(nowSeconds = 3.1, limitSeconds = SilencePolicy.limitSeconds(backgrounded = false)))
    }
}
