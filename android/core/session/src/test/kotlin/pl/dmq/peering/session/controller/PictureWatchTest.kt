package pl.dmq.peering.session.controller

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.testing.FakeClock

class PictureWatchTest {
    private val clock = FakeClock()
    private val watch = PictureWatch(clock, lane = null)

    @Test
    fun aPictureStillWaitingAfterTheStallTimeIsAskedForAgainOnce() {
        assertFalse(watch.takeAutomaticRetry())
        clock.advance(6.0)
        assertTrue(watch.takeAutomaticRetry())
        watch.restart()
        assertFalse(watch.takeAutomaticRetry())
    }

    @Test
    fun itGivesUpAfterThreeTriesAndLeavesRetryToTheUser() {
        repeat(3) {
            clock.advance(6.0)
            assertTrue(watch.takeAutomaticRetry())
            watch.restart()
        }
        clock.advance(6.0)
        assertFalse(watch.takeAutomaticRetry())
    }

    @Test
    fun aPictureThatArrivedIsNeverRetried() {
        watch.noteSeen()
        clock.advance(60.0)
        assertFalse(watch.takeAutomaticRetry())
    }
}
