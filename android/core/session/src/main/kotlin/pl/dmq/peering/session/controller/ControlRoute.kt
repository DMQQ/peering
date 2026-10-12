package pl.dmq.peering.session.controller

import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.relay.ControlHandoff

/** Where a control connection is dialled: straight to a LAN address, or through the relay with its token. */
sealed interface ControlRoute {
    data class Direct(val address: PeerAddress) : ControlRoute

    data class Relayed(val handoff: ControlHandoff) : ControlRoute
}
