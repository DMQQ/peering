package pl.dmq.peering.feature.pairing

import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.controller.PairingCodeError

sealed interface PairingPhase {
    /** The computer shows six digits and the user types them. [attempts] counts the wrong tries so far. */
    data class EnteringCode(val attempts: Int, val error: PairingCodeError?) : PairingPhase

    data object Waiting : PairingPhase

    data object Done : PairingPhase

    data class Failed(val reason: FailureReason) : PairingPhase
}
