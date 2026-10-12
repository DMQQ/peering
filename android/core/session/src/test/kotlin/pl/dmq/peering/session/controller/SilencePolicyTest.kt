package pl.dmq.peering.session.controller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SilencePolicyTest {
    @Test
    fun theForegroundKeepsTheTightLimit() {
        assertEquals(3.0, SilencePolicy.limitSeconds(backgrounded = false), 0.0)
    }

    @Test
    fun aBackgroundedAppIsGivenMoreRoom() {
        assertTrue(SilencePolicy.limitSeconds(backgrounded = true) > SilencePolicy.limitSeconds(backgrounded = false))
    }
}
