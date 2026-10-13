package pl.dmq.peering.session.controller

import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.relay.ControlHandoff

/** Where a connection is dialled: straight to a LAN address, through the relay with its token, or to the LAN picture lane. */
sealed interface ControlRoute {
    data class Direct(val address: PeerAddress) : ControlRoute

    data class Relayed(val handoff: ControlHandoff) : ControlRoute

    /** The second TCP connection of a local session, which carries only the picture. It dials like [Direct]. */
    data class Video(val address: PeerAddress) : ControlRoute
}
