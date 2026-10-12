package pl.dmq.peering.ui.wiring

import pl.dmq.peering.feature.pairing.PairingPhase
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.controller.SessionFailure
import pl.dmq.peering.session.controller.SessionPhase

/** The pairing screen's view of a session: the six digits, the outcome, or still waiting. */
internal fun SessionPhase.toPairingPhase(): PairingPhase = when (this) {
    is SessionPhase.ConfirmingPairing -> PairingPhase.Confirming(code)
    is SessionPhase.Failed -> PairingPhase.Failed(reason.toFailureReason())
    is SessionPhase.Ready -> PairingPhase.Done
    SessionPhase.Idle, SessionPhase.Ended, is SessionPhase.Connecting, is SessionPhase.Reconnecting -> PairingPhase.Waiting
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
