package pl.dmq.peering.ui.wiring

import pl.dmq.peering.feature.pairing.PairingPhase
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.controller.ConnectFailureKind
import pl.dmq.peering.session.controller.SessionFailure
import pl.dmq.peering.session.controller.SessionPhase

/** The pairing screen's view of a session: the code being typed, the outcome, or still waiting. */
internal fun SessionPhase.toPairingPhase(): PairingPhase = when (this) {
    is SessionPhase.EnteringPairingCode -> PairingPhase.EnteringCode(attempts, error)
    is SessionPhase.Failed -> when (val failure = reason) {
        is SessionFailure.ConnectionFailed -> PairingPhase.ConnectionFailed(failure.kind, failure.cause)
        else -> PairingPhase.Failed(failure.toFailureReason())
    }
    is SessionPhase.Ready -> PairingPhase.Done
    SessionPhase.Idle, is SessionPhase.Connecting -> PairingPhase.Waiting
    // A pairing has no use for a session that ended or is reconnecting: the computer is gone, so the screen must say so.
    SessionPhase.Ended, is SessionPhase.Reconnecting -> PairingPhase.ConnectionFailed(ConnectFailureKind.Closed, null)
}

/** Pairing runs on the local network, so a failure outside the handshake reads as the Mac not being reached. */
internal fun SessionFailure.toFailureReason(): FailureReason = when (this) {
    is SessionFailure.Handshake -> reason
    else -> FailureReason.Unreachable
}

/** The host a session is on while it is connected or may come back connected. */
internal fun connectedHostId(phase: SessionPhase, hostId: String?): String? = when (phase) {
    is SessionPhase.Ready, is SessionPhase.Reconnecting -> hostId
    else -> null
}
