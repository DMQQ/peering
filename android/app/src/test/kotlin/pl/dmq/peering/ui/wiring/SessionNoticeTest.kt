package pl.dmq.peering.ui.wiring

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import pl.dmq.peering.R
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.controller.SessionFailure

class SessionNoticeTest {
    @Test
    fun `a changed key is told apart from other refused handshakes on a live connect`() {
        assertEquals(R.string.session_failed_key_changed, SessionFailure.Handshake(FailureReason.PinMismatch("H")).messageRes())
        assertEquals(R.string.session_failed_wrong_computer, SessionFailure.Handshake(FailureReason.HostIdMismatch("A", "B")).messageRes())
        assertEquals(R.string.session_failed_no_pin, SessionFailure.Handshake(FailureReason.NoPinOnFile("H")).messageRes())
    }

    @Test
    fun `other handshake failures keep the general message`() {
        assertEquals(R.string.session_failed_handshake, SessionFailure.Handshake(FailureReason.CommitmentMismatch).messageRes())
        assertNotEquals(R.string.session_failed_handshake, SessionFailure.Handshake(FailureReason.PinMismatch("H")).messageRes())
    }

    @Test
    fun `a changed key cannot be retried`() {
        assertEquals(false, SessionFailure.Handshake(FailureReason.PinMismatch("H")).canRetry)
    }
}
