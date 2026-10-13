package pl.dmq.peering.session.controller

import pl.dmq.peering.session.ports.DatagramTransport
import pl.dmq.peering.session.ports.Signalling
import pl.dmq.peering.session.relay.RelayEntitlement

/**
 * The relay's two channels: the signalling connection that grants a session, and the datagram socket that carries video.
 * [onRemainingSeconds] hears the relay's own count of the time left whenever a grant carries one.
 * [entitlement] is read at each session request, so a purchase made since the last session counts.
 */
class RelayPorts(
    val signalling: Signalling,
    val datagrams: DatagramTransport,
    val onRemainingSeconds: (Long) -> Unit,
    val entitlement: () -> RelayEntitlement,
)
