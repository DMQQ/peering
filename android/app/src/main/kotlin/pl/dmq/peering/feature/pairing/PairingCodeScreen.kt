package pl.dmq.peering.feature.pairing

import pl.dmq.peering.session.controller.PairingCodeError

sealed interface PairingCodeScreen {
    /** Only a finished pairing leaves its connection open. Any other way off this screen closes it. */
    val keepsConnection: Boolean get() = this is Done

    data class EnteringCode(val attempts: Int, val error: PairingCodeError?) : PairingCodeScreen

    /** The phone is still opening the connection, so there is nothing yet for the computer to approve. */
    data object Connecting : PairingCodeScreen

    /** The digits were answered and the computer is being asked to approve. */
    data object Waiting : PairingCodeScreen

    data object Done : PairingCodeScreen

    data class Failed(val message: PairingMessage, val details: String? = null) : PairingCodeScreen

    data object Cancelled : PairingCodeScreen
}
