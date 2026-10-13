package pl.dmq.peering.session.controller

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.testing.FakeClock

class PictureWatchTest {
    private val clock = FakeClock()
    private val watch = PictureWatch(clock, lane = null)

    @Test
    fun aPictureStillWaitingAfterTheStallTimeIsNudgedOncePerInterval() {
        assertEquals(PictureEscalation.NONE, watch.takeEscalation())
        clock.advance(6.0)
        assertEquals(PictureEscalation.KEYFRAME, watch.takeEscalation())
        assertEquals(PictureEscalation.NONE, watch.takeEscalation())
        clock.advance(6.0)
        assertEquals(PictureEscalation.KEYFRAME, watch.takeEscalation())
    }

    @Test
    fun afterThreeNudgesItWaitsThenReopensThePictureOnce() {
        repeat(3) {
            clock.advance(6.0)
            assertEquals(PictureEscalation.KEYFRAME, watch.takeEscalation())
        }
        clock.advance(6.0)
        assertEquals(PictureEscalation.NONE, watch.takeEscalation())
        clock.advance(6.0)
        assertEquals(PictureEscalation.REOPEN, watch.takeEscalation())
    }

    @Test
    fun aPictureThatStillDoesNotComeAfterTheReopenReplacesTheConnection() {
        clock.advance(30.0)
        assertEquals(PictureEscalation.REOPEN, watch.takeEscalation())
        watch.restart(automatic = true)
        clock.advance(30.0)
        assertEquals(PictureEscalation.RECONNECT, watch.takeEscalation())
    }

    @Test
    fun aPersonAskingToRetryStartsTheEscalationOver() {
        clock.advance(30.0)
        watch.restart(automatic = true)
        watch.restart()
        clock.advance(30.0)
        assertEquals(PictureEscalation.REOPEN, watch.takeEscalation())
    }

    @Test
    fun aPictureThatArrivedIsNeverEscalated() {
        watch.noteSeen()
        clock.advance(120.0)
        assertEquals(PictureEscalation.NONE, watch.takeEscalation())
    }
}
