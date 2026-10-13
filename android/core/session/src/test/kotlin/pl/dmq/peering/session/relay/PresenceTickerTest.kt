package pl.dmq.peering.session.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.testing.FakeClock

class PresenceTickerTest {
    private val clock = FakeClock(monotonic = 100.0)
    private val ticker = PresenceTicker(clock, intervalSeconds = 15.0)

    @Test
    fun theFirstAskIsDueAtOnce() {
        assertTrue(ticker.isDue())
        assertEquals(0.0, ticker.secondsUntilDue(), 0.0)
    }

    @Test
    fun anAskIsNotDueAgainBeforeTheIntervalHasPassed() {
        ticker.markAsked()
        clock.advance(5.0)

        assertFalse(ticker.isDue())
        assertEquals(10.0, ticker.secondsUntilDue(), 1e-9)
    }

    @Test
    fun anAskIsDueAgainOnceTheIntervalHasPassed() {
        ticker.markAsked()
        clock.advance(15.0)

        assertTrue(ticker.isDue())
    }
}
