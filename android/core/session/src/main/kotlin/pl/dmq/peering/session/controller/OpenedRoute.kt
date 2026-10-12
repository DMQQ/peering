package pl.dmq.peering.session.controller

import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.ports.ControlTransport
import pl.dmq.peering.session.ports.DatagramTransport
import pl.dmq.peering.session.ports.PeerAddress

/**
 * A control connection that is open, and the video lane that goes with it. A LAN route has no datagram lane, so its
 * [videoPeer] and [videoToken] are never used.
 */
class OpenedRoute(
    val transport: ControlTransport,
    val path: SessionRecord.Path,
    val videoPeer: PeerAddress,
    val videoToken: ByteArray,
    val datagrams: DatagramTransport?,
)
