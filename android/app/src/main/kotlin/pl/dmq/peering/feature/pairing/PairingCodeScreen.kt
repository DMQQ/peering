package pl.dmq.peering.feature.pairing

import pl.dmq.peering.session.controller.PairingCodeError

sealed interface PairingCodeScreen {
    data class EnteringCode(val attempts: Int, val error: PairingCodeError?) : PairingCodeScreen

    data object Waiting : PairingCodeScreen

    data object Done : PairingCodeScreen

    data class Failed(val message: PairingMessage) : PairingCodeScreen

    data object Cancelled : PairingCodeScreen
}
