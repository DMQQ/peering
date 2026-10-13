package pl.dmq.peering.feature.connect

import pl.dmq.peering.session.ports.DiscoveredHost

/** The two lists the Connect screen shows. A paired host that is on the network is in both, as on the iPhone. */
data class HostListing(val paired: List<HostRow>, val nearby: List<HostRow>) {
    companion object {
        val EMPTY = HostListing(emptyList(), emptyList())

        fun of(
            nearby: List<DiscoveredHost>,
            paired: List<PairedHost>,
            online: Set<String>,
            connected: String?,
        ): HostListing {
            val nearbyById = nearby.associateBy { it.id }

            fun statusOf(id: String): HostStatus = when {
                id == connected -> HostStatus.Connected
                id in online || id in nearbyById -> HostStatus.Online
                else -> HostStatus.Unknown
            }

            fun routeOf(id: String): HostRoute = when {
                id in nearbyById -> HostRoute.Local
                id in online -> HostRoute.Relay
                else -> HostRoute.None
            }

            val pairedRows = paired.map { host ->
                val status = statusOf(host.id)
                val wake = when {
                    !host.canWake -> WakeState.NoAddress
                    status != HostStatus.Unknown -> WakeState.Awake
                    else -> WakeState.Available
                }
                HostRow(host.id, host.name ?: nearbyById[host.id]?.name, status, routeOf(host.id), wake)
            }
            val nearbyRows = nearbyById.values
                .map { HostRow(it.id, it.name, statusOf(it.id), HostRoute.Local) }

            return HostListing(
                paired = HostOrdering.order(pairedRows),
                nearby = HostOrdering.order(nearbyRows),
            )
        }
    }
}
