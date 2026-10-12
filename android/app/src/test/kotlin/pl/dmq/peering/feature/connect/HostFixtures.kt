package pl.dmq.peering.feature.connect

import pl.dmq.peering.session.ports.DiscoveredHost
import pl.dmq.peering.session.ports.PeerAddress

internal fun nearbyHost(id: String, name: String = "Studio Mac"): DiscoveredHost =
    DiscoveredHost(id = id, name = name, protocolVersion = 20, address = PeerAddress("192.168.1.20", 7000))
