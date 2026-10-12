package pl.dmq.peering.feature.connect

import pl.dmq.peering.session.ports.DiscoveredHost

/** The two lists the Connect screen shows. A host that is both paired and nearby appears only among the paired. */
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
            val pairedIds = paired.map { it.id }.toSet()

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
                HostRow(host.id, host.name ?: nearbyById[host.id]?.name, statusOf(host.id), routeOf(host.id))
            }
            val nearbyRows = nearbyById.values
                .filter { it.id !in pairedIds }
                .map { HostRow(it.id, it.name, statusOf(it.id), HostRoute.Local) }

            return HostListing(
                paired = HostOrdering.order(pairedRows),
                nearby = HostOrdering.order(nearbyRows),
            )
        }
    }
}
