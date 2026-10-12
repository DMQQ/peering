package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import pl.dmq.peering.session.ports.KeyValueStore

/** Names the user gave trusted computers. They live on this device only: the computer keeps its own name. */
internal class HostAliases(private val store: KeyValueStore, hostIds: () -> Set<String>) {
    private val current = MutableStateFlow(hostIds().mapNotNull { id -> store.read(key(id))?.let { id to it } }.toMap())
    val names: StateFlow<Map<String, String>> = current.asStateFlow()

    /** A blank [name] drops the alias. */
    fun set(hostId: String, name: String) {
        store.write(key(hostId), name)
        current.update { if (name.isBlank()) it - hostId else it + (hostId to name) }
    }

    private fun key(hostId: String) = "host_alias_$hostId"
}
