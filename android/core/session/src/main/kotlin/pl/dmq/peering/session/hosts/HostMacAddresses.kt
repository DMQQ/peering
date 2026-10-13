package pl.dmq.peering.session.hosts

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.session.ports.KeyValueStore

/**
 * The hardware addresses each paired computer gave in its hello, so it can be woken while it sleeps. The values come off
 * the wire, so each is clipped before it is kept.
 */
class HostMacAddresses(private val store: KeyValueStore) {
    private val entries = MutableStateFlow(read())

    /** Every computer's addresses, by device ID. Emits the whole map each time it changes. */
    val known: StateFlow<Map<String, List<String>>> = entries.asStateFlow()

    fun of(hostId: String): List<String> = entries.value[hostId].orEmpty()

    /** Keeps the addresses a computer just reported. An empty report leaves what is kept, since a host may omit them. */
    @Synchronized
    fun remember(hostId: String, addresses: List<String>) {
        val clipped = addresses.map { it.take(MAXIMUM_CHARACTERS) }
            .filter { it.isNotBlank() && SEPARATORS.none(it::contains) }
            .take(MAXIMUM_ADDRESSES)
        if (clipped.isEmpty() || entries.value[hostId] == clipped) return
        replaceWith(entries.value + (hostId to clipped))
    }

    @Synchronized
    fun forget(hostId: String) {
        if (hostId in entries.value) replaceWith(entries.value - hostId)
    }

    private fun replaceWith(next: Map<String, List<String>>) {
        entries.value = next
        store.write(KEY, next.entries.joinToString("\n") { "${it.key}$HOST_SEPARATOR${it.value.joinToString(ADDRESS_SEPARATOR)}" })
    }

    private fun read(): Map<String, List<String>> = store.read(KEY).orEmpty().lines()
        .mapNotNull { line -> line.split(HOST_SEPARATOR, limit = 2).takeIf { it.size == 2 } }
        .associate { (id, joined) -> id to joined.split(ADDRESS_SEPARATOR).filter { it.isNotBlank() } }

    private companion object {
        const val KEY = "host-mac-addresses"
        const val HOST_SEPARATOR = "|"
        const val ADDRESS_SEPARATOR = ","
        val SEPARATORS = listOf(HOST_SEPARATOR, ADDRESS_SEPARATOR, "\n")
        const val MAXIMUM_ADDRESSES = 8
        const val MAXIMUM_CHARACTERS = 17
    }
}
