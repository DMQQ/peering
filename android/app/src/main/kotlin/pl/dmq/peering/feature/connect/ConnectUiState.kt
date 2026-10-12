package pl.dmq.peering.feature.connect

import pl.dmq.peering.feature.pairing.HostIdEntryState

data class ConnectUiState(
    val listing: HostListing = HostListing.EMPTY,
    /** The trusted host the user has asked to forget, awaiting confirmation. */
    val forgetTarget: HostRow? = null,
    val message: ConnectMessage? = null,
    val entry: HostIdEntryState = HostIdEntryState(),
)

enum class ConnectMessage { ForgetFailed }
