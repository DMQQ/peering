package pl.dmq.peering.ui.wiring

import pl.dmq.peering.session.controller.ConnectTarget
import pl.dmq.peering.session.ports.PeerAddress

/** A paired Mac is dialled on the local network when it is, or was, seen there, with the relay only behind that. */
internal fun pairedTarget(hostId: String, discovered: PeerAddress?, remembered: PeerAddress?): ConnectTarget =
    ConnectTarget.Paired(hostId, discovered, remembered, relayAllowed = true)
