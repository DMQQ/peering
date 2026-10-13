package pl.dmq.peering.session.ports

/** A host found on the local network. [protocolVersion] is null when its advertisement did not say. */
data class DiscoveredHost(
    val id: String,
    val name: String,
    val protocolVersion: Int?,
    val address: PeerAddress,
)
