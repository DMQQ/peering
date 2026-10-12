package pl.dmq.peering.ui.wiring

import pl.dmq.peering.session.controller.SessionFailure
import pl.dmq.peering.session.controller.SessionPhase

/**
 * A session that was lost while the app was away is tried once more when the app comes back, because Android stops the
 * connection of a backgrounded app and the person did nothing wrong. One retry per loss: a second failure is shown.
 */
internal class ForegroundRetry {
    private var inForeground = true
    private var lostAway = false
    private var retried = false

    fun onPhase(phase: SessionPhase) {
        when {
            phase is SessionPhase.Ready -> {
                lostAway = false
                retried = false
            }
            phase.isConnectionLost() && !inForeground -> lostAway = true
        }
    }

    /** True when the session should be started again now. */
    fun onForeground(foreground: Boolean, phase: SessionPhase): Boolean {
        inForeground = foreground
        if (!foreground || !lostAway || retried || !phase.isConnectionLost()) return false
        lostAway = false
        retried = true
        return true
    }

    private fun SessionPhase.isConnectionLost(): Boolean =
        this is SessionPhase.Failed && reason == SessionFailure.ConnectionLost && canRetry
}
