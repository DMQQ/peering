package pl.dmq.peering.session.controller

import pl.dmq.peering.session.ports.DatagramTransport
import pl.dmq.peering.session.ports.Signalling

/** The relay's two channels: the signalling connection that grants a session, and the datagram socket that carries video. */
class RelayPorts(val signalling: Signalling, val datagrams: DatagramTransport)
