package pl.dmq.peering.session.ports

/** A change in the hosts visible on the local network. */
sealed interface DiscoveryEvent {
    /** A host appeared, or its address changed. */
    data class Found(val host: DiscoveredHost) : DiscoveryEvent

    /** A host is no longer advertised, so whatever address was held for it is stale. */
    data class Lost(val hostId: String) : DiscoveryEvent
}
