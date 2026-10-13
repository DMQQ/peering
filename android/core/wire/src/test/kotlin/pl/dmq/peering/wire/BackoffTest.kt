package pl.dmq.peering.wire

import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BackoffTest {
    @Test
    fun theLadderStepsThroughTheDelaysThenStops() {
        val ladder = ReconnectLadder()
        assertEquals(500.milliseconds, ladder.next())
        assertEquals(1.seconds, ladder.next())
        assertEquals(2.seconds, ladder.next())
        assertEquals(5.seconds, ladder.next())
        assertEquals(5.seconds, ladder.next())
        assertNull(ladder.next())
        assertNull(ladder.next())
    }

    @Test
    fun resetStartsTheLadderAgainFromTheShortFirstDelay() {
        val ladder = ReconnectLadder()
        repeat(5) { ladder.next() }
        ladder.reset()
        assertEquals(500.milliseconds, ladder.next())
    }

    @Test
    fun resetPartWayThroughRestartsTheLadder() {
        val ladder = ReconnectLadder()
        ladder.next()
        ladder.next()
        ladder.reset()
        assertEquals(500.milliseconds, ladder.next())
    }
}
