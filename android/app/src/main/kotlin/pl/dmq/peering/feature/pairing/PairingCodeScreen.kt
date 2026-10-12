package pl.dmq.peering.feature.pairing

sealed interface PairingCodeScreen {
    data class Comparing(val code: String) : PairingCodeScreen

    data object Waiting : PairingCodeScreen

    data object Done : PairingCodeScreen

    data class Failed(val message: PairingMessage) : PairingCodeScreen

    data object Cancelled : PairingCodeScreen
}
