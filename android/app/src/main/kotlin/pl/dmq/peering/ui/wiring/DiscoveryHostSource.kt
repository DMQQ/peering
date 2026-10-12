package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import pl.dmq.peering.feature.connect.HostSource
import pl.dmq.peering.feature.connect.PairedHost
import pl.dmq.peering.session.hosts.HostDirectory
import pl.dmq.peering.session.ports.DiscoveredHost
import pl.dmq.peering.session.ports.Discovery
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.ports.PinStore

/** Hosts from local discovery, and the paired hosts from the pin store, named from the directory. Discovery runs while the app is open. */
internal class DiscoveryHostSource(
    private val discovery: Discovery,
    private val pins: PinStore,
    private val directory: HostDirectory,
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

    override fun pairedHosts(): Flow<List<PairedHost>> = directory.known.map { known ->
        pins.hostIds().map { PairedHost(id = it, name = known[it]?.name) }
    }

    override fun forget(hostId: String): Boolean {
        val removed = pins.remove(hostId)
        if (removed) directory.forget(hostId)
        return removed
    }

    override fun restartSearch() {
        search?.cancel()
        search = scope.launch {
            discovery.hosts().collect { host -> found.update { it.withFound(host) } }
        }
    }
}
