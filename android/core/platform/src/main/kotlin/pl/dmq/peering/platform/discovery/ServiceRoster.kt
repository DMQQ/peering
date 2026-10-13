package pl.dmq.peering.platform.discovery

import pl.dmq.peering.session.ports.DiscoveredHost
import pl.dmq.peering.session.ports.DiscoveryEvent

/**
 * The resolved services by name, turned into per-host events. A host with two services (a renamed Mac keeps its old
 * advertisement for a while) shows the most recently resolved one, and is lost only when its last service is.
 */
class ServiceRoster {
    private val byService = linkedMapOf<String, DiscoveredHost>()
    private var shown = emptyMap<String, DiscoveredHost>()

    fun found(serviceName: String, host: DiscoveredHost): List<DiscoveryEvent> {
        byService.remove(serviceName)
        byService[serviceName] = host
        return changes()
    }

    fun lost(serviceName: String): List<DiscoveryEvent> {
        byService.remove(serviceName)
        return changes()
    }

    private fun changes(): List<DiscoveryEvent> {
        val now = byService.values.reversed().distinctBy { it.id }.associateBy { it.id }
        val events = shown.keys.filter { it !in now }.map { DiscoveryEvent.Lost(it) } +
            now.values.filter { shown[it.id] != it }.map { DiscoveryEvent.Found(it) }
        shown = now
        return events
    }
}
