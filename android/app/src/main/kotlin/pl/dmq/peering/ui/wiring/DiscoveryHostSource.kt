package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import pl.dmq.peering.feature.connect.HostSource
import pl.dmq.peering.feature.connect.PairedHost
import pl.dmq.peering.session.hosts.HostDirectory
import pl.dmq.peering.session.hosts.RememberedLanAddresses
import pl.dmq.peering.session.ports.DiscoveredHost
import pl.dmq.peering.session.ports.Discovery
import pl.dmq.peering.session.ports.DiscoveryEvent
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.ports.PinStore

/** Hosts from local discovery, and the paired hosts from the pin store, named from the directory. Discovery runs while the app is open. */
internal class DiscoveryHostSource(
    private val discovery: Discovery,
    private val pins: PinStore,
    private val directory: HostDirectory,
    private val lanAddresses: RememberedLanAddresses,
    private val aliases: HostAliases,
    private val scope: CoroutineScope,
) : HostSource {
    private val found = MutableStateFlow<List<DiscoveredHost>>(emptyList())
    private var search: Job? = null

    init {
        restartSearch()
    }

    /** The address a nearby host was last seen at, or null when it is not on the network now. */
    fun addressOf(hostId: String): PeerAddress? = found.value.firstOrNull { it.id == hostId }?.address

    override fun nearbyHosts(): Flow<List<DiscoveredHost>> = found.asStateFlow()

    override fun pairedHosts(): Flow<List<PairedHost>> = combine(directory.known, aliases.names) { known, named ->
        pins.hostIds().map { PairedHost(id = it, name = named[it] ?: known[it]?.name) }
    }

    override fun rename(hostId: String, name: String) = aliases.set(hostId, name)

    override fun forget(hostId: String): Boolean {
        val removed = pins.remove(hostId)
        if (removed) directory.forget(hostId)
        return removed
    }

    override fun restartSearch() {
        search?.cancel()
        found.value = emptyList()
        search = scope.launch {
            discovery.events().collect { event ->
                when (event) {
                    is DiscoveryEvent.Found -> {
                        found.update { it.withFound(event.host) }
                        if (event.host.id in pins.hostIds()) lanAddresses.remember(event.host.id, event.host.address)
                    }
                    is DiscoveryEvent.Lost -> found.update { list -> list.filterNot { it.id == event.hostId } }
                }
            }
        }
    }
}
