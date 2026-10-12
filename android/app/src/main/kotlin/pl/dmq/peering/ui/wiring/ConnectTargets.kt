package pl.dmq.peering.ui.wiring

import pl.dmq.peering.session.controller.ConnectTarget
import pl.dmq.peering.session.ports.PeerAddress

/** A paired Mac seen on the local network is dialled there; one that is not is reached through the relay. */
internal fun pairedTarget(hostId: String, localAddress: PeerAddress?): ConnectTarget =
    if (localAddress != null) ConnectTarget.Lan(localAddress, hostId) else ConnectTarget.Relay(hostId)
