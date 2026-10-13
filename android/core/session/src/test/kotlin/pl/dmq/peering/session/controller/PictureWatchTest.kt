package pl.dmq.peering.session.controller

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.testing.FakeClock

class PictureWatchTest {
    private val clock = FakeClock()
    private val watch = PictureWatch(clock, lane = null)

    @Test
    fun aPictureStillWaitingAfterTheStallTimeIsNudgedOncePerInterval() {
        assertFalse(watch.takeAutomaticNudge())
        clock.advance(6.0)
        assertTrue(watch.takeAutomaticNudge())
        assertFalse(watch.takeAutomaticNudge())
        clock.advance(6.0)
        assertTrue(watch.takeAutomaticNudge())
    }

    @Test
    fun itGivesUpAfterThreeNudgesAndLeavesRetryToTheUser() {
        repeat(3) {
            clock.advance(6.0)
            assertTrue(watch.takeAutomaticNudge())
        }
        clock.advance(60.0)
        assertFalse(watch.takeAutomaticNudge())
    }

    @Test
    fun aPictureThatArrivedIsNeverRetried() {
        watch.noteSeen()
        clock.advance(60.0)
        assertFalse(watch.takeAutomaticNudge())
    }
}
