package pl.dmq.peering.session.hosts

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.ports.KeyValueStore

class PersistedHostDirectoryTest {
    private val store = MemoryKeyValueStore()

    @Test
    fun aRememberedNameAndRouteAreReadBackByALaterDirectory() {
        PersistedHostDirectory(store).remember("MAC-1", "Studio Mac", SessionRecord.Path.RELAY)

        val reopened = PersistedHostDirectory(store)

        assertEquals(mapOf("MAC-1" to KnownHost("Studio Mac", SessionRecord.Path.RELAY)), reopened.known.value)
    }

    @Test
    fun aBlankNameIsNotRemembered() {
        val directory = PersistedHostDirectory(store)

        directory.remember("MAC-1", "   ", SessionRecord.Path.LAN)

        assertTrue(directory.known.value.isEmpty())
        assertEquals(0, store.writes)
    }

    @Test
    fun aNameAndRouteThatDidNotChangeAreNotWrittenAgain() {
        val directory = PersistedHostDirectory(store)

        directory.remember("MAC-1", "Studio Mac", SessionRecord.Path.LAN)
        directory.remember("MAC-1", "Studio Mac", SessionRecord.Path.LAN)

        assertEquals(1, store.writes)
    }

    @Test
    fun aChangedRouteIsWrittenAsANewEntry() {
        val directory = PersistedHostDirectory(store)

        directory.remember("MAC-1", "Studio Mac", SessionRecord.Path.LAN)
        directory.remember("MAC-1", "Studio Mac", SessionRecord.Path.RELAY)

        assertEquals(KnownHost("Studio Mac", SessionRecord.Path.RELAY), directory.known.value["MAC-1"])
        assertEquals(2, store.writes)
    }

    @Test
    fun forgetRemovesTheEntryAndTheRemovalIsStored() {
        val directory = PersistedHostDirectory(store)
        directory.remember("MAC-1", "Studio Mac", SessionRecord.Path.LAN)

        directory.forget("MAC-1")

        assertTrue(directory.known.value.isEmpty())
        assertTrue(PersistedHostDirectory(store).known.value.isEmpty())
    }

    @Test
    fun anUnreadableStoredValueStartsTheDirectoryEmpty() {
        store.write("paired-host-names", "{not json")

        assertTrue(PersistedHostDirectory(store).known.value.isEmpty())
    }

    private class MemoryKeyValueStore : KeyValueStore {
        private val values = mutableMapOf<String, String>()
        var writes = 0
            private set

        override fun read(key: String): String? = values[key]

        override fun write(key: String, value: String) {
            writes += 1
            values[key] = value
        }
    }
}
