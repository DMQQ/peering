package pl.dmq.peering.feature.connect

import pl.dmq.peering.feature.pairing.HostIdEntryState

data class ConnectUiState(
    val listing: HostListing = HostListing.EMPTY,
    val nearbyPhase: NearbyPhase = NearbyPhase.Searching,
    /** The trusted host the user has asked to forget, awaiting confirmation. */
    val forgetTarget: HostRow? = null,
    val message: ConnectMessage? = null,
    val entry: HostIdEntryState = HostIdEntryState(),
)

/** A note under the Connect header. [isFailure] says whether it reports something that went wrong or something that was done. */
sealed interface ConnectMessage {
    val isFailure: Boolean get() = true

    data object ForgetFailed : ConnectMessage

    data object WakeNoAddress : ConnectMessage

    /** Addresses were on file but none could be read, so no packet went out. */
    data object WakeUnreadable : ConnectMessage

    data class WakeSent(val count: Int) : ConnectMessage {
        override val isFailure: Boolean get() = false
    }
}
