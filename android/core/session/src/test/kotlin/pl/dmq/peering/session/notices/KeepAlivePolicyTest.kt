package pl.dmq.peering.session.notices

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.session.controller.SessionFailure
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.history.SessionRecord

class KeepAlivePolicyTest {
    private val ready = SessionPhase.Ready("Mac", emptySet(), SessionRecord.Path.LAN)

    @Test
    fun theServiceRunsFromConnectingThroughReconnecting() {
        assertEquals(KeepAliveStatus.Connecting, KeepAlivePolicy.statusFor(true, SessionPhase.Connecting(SessionRecord.Path.LAN)))
        assertEquals(KeepAliveStatus.Connected, KeepAlivePolicy.statusFor(true, ready))
        assertEquals(KeepAliveStatus.Reconnecting, KeepAlivePolicy.statusFor(true, SessionPhase.Reconnecting(2)))
    }

    @Test
    fun theServiceStopsWhenTheSessionIsOverOrNotYetPaired() {
        assertNull(KeepAlivePolicy.statusFor(true, SessionPhase.Ended))
        assertNull(KeepAlivePolicy.statusFor(true, SessionPhase.Idle))
        assertNull(KeepAlivePolicy.statusFor(true, SessionPhase.EnteringPairingCode(0)))
        assertNull(KeepAlivePolicy.statusFor(true, SessionPhase.Failed(SessionFailure.ConnectionLost, canRetry = true)))
        assertNull(KeepAlivePolicy.statusFor(true, null))
    }

    @Test
    fun theSettingTurnsItOff() {
        assertNull(KeepAlivePolicy.statusFor(false, ready))
    }
}
