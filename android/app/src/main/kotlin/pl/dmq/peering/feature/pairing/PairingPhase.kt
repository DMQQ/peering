package pl.dmq.peering.feature.pairing

import pl.dmq.peering.session.connection.FailureReason

sealed interface PairingPhase {
    /** The six digits the Mac shows, for the user to compare with the ones on this screen. */
    data class Confirming(val code: String) : PairingPhase

    data object Waiting : PairingPhase

    data object Done : PairingPhase

    data class Failed(val reason: FailureReason) : PairingPhase
}
