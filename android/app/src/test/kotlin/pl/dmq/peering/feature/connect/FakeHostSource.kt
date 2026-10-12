package pl.dmq.peering.feature.connect

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import pl.dmq.peering.session.ports.DiscoveredHost

class FakeHostSource(
    nearby: List<DiscoveredHost> = emptyList(),
    paired: List<PairedHost> = emptyList(),
    private val forgetSucceeds: Boolean = true,
) : HostSource {
    val nearby = MutableStateFlow(nearby)
    val paired = MutableStateFlow(paired)
    val forgotten = mutableListOf<String>()
    val renamed = mutableListOf<Pair<String, String>>()
    var searchRestarts = 0
        private set

    override fun nearbyHosts(): Flow<List<DiscoveredHost>> = nearby

    override fun pairedHosts(): Flow<List<PairedHost>> = paired

    override fun forget(hostId: String): Boolean {
        forgotten += hostId
        if (forgetSucceeds) paired.value = paired.value.filterNot { it.id == hostId }
        return forgetSucceeds
    }

    override fun rename(hostId: String, name: String) {
        renamed += hostId to name
    }

    override fun restartSearch() {
        searchRestarts++
    }
}
