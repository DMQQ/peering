package pl.dmq.peering.session.controller

import pl.dmq.peering.session.connection.HostCapability
import pl.dmq.peering.session.history.SessionRecord

/** Where the session stands from the user's side. */
sealed interface SessionPhase {
    data object Idle : SessionPhase

    data class Connecting(val path: SessionRecord.Path) : SessionPhase

    data class ConfirmingPairing(val code: String) : SessionPhase

    data class Ready(
        val hostName: String,
        val capabilities: Set<HostCapability>,
        val path: SessionRecord.Path,
    ) : SessionPhase

    data class Reconnecting(val attempt: Int) : SessionPhase

    data class Failed(val reason: SessionFailure, val canRetry: Boolean) : SessionPhase

    data object Ended : SessionPhase
}
