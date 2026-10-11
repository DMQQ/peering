package pl.dmq.peering.session.relay

import pl.dmq.peering.session.ports.PeerAddress

/** What the attempt at a direct path to the Mac has come to. [Open] means a datagram from [PeerAddress] authenticated. */
sealed interface DirectPathState {
    data object NotTried : DirectPathState

    data class Probing(val peer: PeerAddress) : DirectPathState

    data class Open(val peer: PeerAddress) : DirectPathState

    data object NoAddress : DirectPathState

    data class AddressUnusable(val peer: PeerAddress) : DirectPathState
}
