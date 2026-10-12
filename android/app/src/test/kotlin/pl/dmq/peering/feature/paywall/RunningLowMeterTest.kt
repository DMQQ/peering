package pl.dmq.peering.feature.paywall

import org.junit.Assert.assertEquals
import org.junit.Test

class RunningLowMeterTest {
    @Test
    fun halfTheAllowanceFillsHalfTheBar() {
        assertEquals(0.5f, runningLowFraction(900, 1800), 0f)
    }

    @Test
    fun timeBeyondTheAllowanceFillsTheBarAndNothingGoesBelowEmpty() {
        assertEquals(1f, runningLowFraction(4000, 1800), 0f)
        assertEquals(0f, runningLowFraction(-5, 1800), 0f)
    }

    @Test
    fun noAllowanceDrawsAnEmptyBar() {
        assertEquals(0f, runningLowFraction(100, 0), 0f)
    }
}
