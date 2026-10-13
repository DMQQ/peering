package pl.dmq.peering.session.hosts

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.ports.KeyValueStore

/** [HostDirectory] kept as one JSON map in [store]. A stored value that cannot be read starts the directory empty. */
class PersistedHostDirectory(private val store: KeyValueStore) : HostDirectory {
    private val entries = MutableStateFlow(decode(store.read(KEY)))

    override val known: StateFlow<Map<String, KnownHost>> = entries.asStateFlow()

    @Synchronized
    override fun remember(hostId: String, name: String, path: SessionRecord.Path) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        val next = KnownHost(trimmed, path)
        if (entries.value[hostId] == next) return
        replaceWith(entries.value + (hostId to next))
    }

    @Synchronized
    override fun forget(hostId: String) {
        if (hostId !in entries.value) return
        replaceWith(entries.value - hostId)
    }

    private fun replaceWith(next: Map<String, KnownHost>) {
        entries.value = next
        store.write(KEY, STORAGE.encodeToString(MAP_SERIALIZER, next))
    }

    private companion object {
        const val KEY = "paired-host-names"

        val STORAGE = Json { ignoreUnknownKeys = true }
        val MAP_SERIALIZER = MapSerializer(String.serializer(), KnownHost.serializer())

        fun decode(text: String?): Map<String, KnownHost> {
            if (text == null) return emptyMap()
            return try {
                STORAGE.decodeFromString(MAP_SERIALIZER, text)
            } catch (unreadable: SerializationException) {
                emptyMap()
            }
        }
    }
}
