package pl.dmq.peering.ui.wiring

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.controller.SessionFailure
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.history.SessionRecord

class ForegroundRetryTest {
    private val lost = SessionPhase.Failed(SessionFailure.ConnectionLost, canRetry = true)
    private val retry = ForegroundRetry()

    @Test
    fun aLossWhileAwayIsRetriedOnReturn() {
        retry.onForeground(false, SessionPhase.Idle)
        retry.onPhase(lost)

        assertTrue(retry.onForeground(true, lost))
    }

    @Test
    fun aLossWhileInUseIsLeftForThePersonToSee() {
        retry.onPhase(lost)
        retry.onForeground(false, lost)

        assertFalse(retry.onForeground(true, lost))
    }

    @Test
    fun theRetryHappensOnlyOnce() {
        retry.onForeground(false, SessionPhase.Idle)
        retry.onPhase(lost)
        assertTrue(retry.onForeground(true, lost))

        retry.onForeground(false, lost)
        retry.onPhase(lost)

        assertFalse(retry.onForeground(true, lost))
    }

    @Test
    fun aReadySessionRestoresTheRetry() {
        retry.onForeground(false, SessionPhase.Idle)
        retry.onPhase(lost)
        assertTrue(retry.onForeground(true, lost))
        retry.onPhase(SessionPhase.Ready("Studio", emptySet(), SessionRecord.Path.LAN))

        retry.onForeground(false, SessionPhase.Idle)
        retry.onPhase(lost)

        assertTrue(retry.onForeground(true, lost))
    }

    @Test
    fun otherFailuresAreNotRetried() {
        val refused = SessionPhase.Failed(SessionFailure.ConnectionLost, canRetry = false)
        retry.onForeground(false, SessionPhase.Idle)
        retry.onPhase(refused)

        assertFalse(retry.onForeground(true, refused))
    }
}
