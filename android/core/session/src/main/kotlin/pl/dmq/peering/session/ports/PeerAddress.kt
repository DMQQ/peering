package pl.dmq.peering.session.ports

/** A host and port the transport can reach: an IP literal or a name the platform resolves. */
data class PeerAddress(val host: String, val port: Int)
