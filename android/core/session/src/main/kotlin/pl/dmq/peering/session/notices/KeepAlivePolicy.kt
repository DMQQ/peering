package pl.dmq.peering.session.notices

import pl.dmq.peering.session.controller.SessionPhase

/** What the ongoing notification of the background service says about the session. */
enum class KeepAliveStatus { Connecting, Connected, Reconnecting }

/**
 * When the foreground service runs: from the moment the user starts a session until it ends, fails or is disconnected.
 * It starts while the app is on screen, because Android refuses to start one from the background. Waiting for pairing
 * digits is not a session worth keeping: the user is in the app for it.
 */
object KeepAlivePolicy {
    fun statusFor(enabled: Boolean, phase: SessionPhase?): KeepAliveStatus? {
        if (!enabled) return null
        return when (phase) {
            is SessionPhase.Connecting -> KeepAliveStatus.Connecting
            is SessionPhase.Ready -> KeepAliveStatus.Connected
            is SessionPhase.Reconnecting -> KeepAliveStatus.Reconnecting
            is SessionPhase.EnteringPairingCode, is SessionPhase.Failed, SessionPhase.Idle, SessionPhase.Ended, null -> null
        }
    }
}
