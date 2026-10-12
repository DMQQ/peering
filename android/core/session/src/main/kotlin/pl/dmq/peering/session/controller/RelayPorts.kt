package pl.dmq.peering.session.controller

import pl.dmq.peering.session.ports.DatagramTransport
import pl.dmq.peering.session.ports.Signalling
import pl.dmq.peering.session.relay.RelayEntitlement

/**
 * The relay's two channels: the signalling connection that grants a session, and the datagram socket that carries video.
 * [entitlement] is read at each session request, so a purchase made since the last session counts.
 */
class RelayPorts(
    val signalling: Signalling,
    val datagrams: DatagramTransport,
    val entitlement: () -> RelayEntitlement,
)
