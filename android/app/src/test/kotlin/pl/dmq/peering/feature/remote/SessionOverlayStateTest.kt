package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.session.history.SessionRecord

class SessionOverlayStateTest {
    @Test
    fun `a relay session with few minutes left shows a low notice with the minutes`() {
        val state = SessionOverlayState.of(null, 42, SessionRecord.Path.RELAY, PictureState.LIVE, reconnecting = false, relayMinutesLeft = 3)

        assertEquals(QuotaNotice.Low(3), state.quota)
        assertEquals(42, state.latencyMs)
        assertEquals(SessionRecord.Path.RELAY, state.path)
    }

    @Test
    fun `a relay session with no minutes left shows the exhausted notice`() {
        val state = SessionOverlayState.of(null, null, SessionRecord.Path.RELAY, PictureState.LIVE, reconnecting = false, relayMinutesLeft = 0)

        assertEquals(QuotaNotice.Exhausted, state.quota)
    }

    @Test
    fun `a relay session with plenty of minutes shows no notice`() {
        assertNull(QuotaNotice.of(SessionRecord.Path.RELAY, relayMinutesLeft = 6))
    }

    @Test
    fun `a session that is not on the relay never shows a relay notice`() {
        assertNull(QuotaNotice.of(SessionRecord.Path.LAN, relayMinutesLeft = 0))
        assertNull(QuotaNotice.of(SessionRecord.Path.DIRECT, relayMinutesLeft = 0))
    }

    @Test
    fun `an unlimited plan has no minutes to run out of`() {
        assertNull(QuotaNotice.of(SessionRecord.Path.RELAY, relayMinutesLeft = null))
    }

    @Test
    fun `the picture state and an unknown path pass through unchanged`() {
        val state = SessionOverlayState.of(null, latencyMs = null, path = null, picture = PictureState.PAUSED, reconnecting = false, relayMinutesLeft = null)

        assertEquals(PictureState.PAUSED, state.picture)
        assertNull(state.path)
        assertNull(state.quota)
    }
}
