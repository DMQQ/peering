package pl.dmq.peering.session.ports

/** A datagram with the address it came from, so the caller can authenticate its source. */
class ReceivedDatagram(val source: PeerAddress, val bytes: ByteArray)
