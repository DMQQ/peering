package pl.dmq.peering.feature.sessionmode

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.KeyValueStore

class SessionModeTest {
    private class MapStore : KeyValueStore {
        val values = mutableMapOf<String, String>()
        override fun read(key: String) = values[key]
        override fun write(key: String, value: String) { values[key] = value }
    }

    @Test
    fun workspaceIsOfferedOnlyWhenTheComputerHasSomethingToShow() {
        assertEquals(listOf(SessionMode.SCREEN, SessionMode.REMOTE), SessionMode.available(workspaceOffered = false))
        assertEquals(SessionMode.entries, SessionMode.available(workspaceOffered = true))
    }

    @Test
    fun onlyTheScreenNeedsAPicture() {
        assertTrue(SessionMode.SCREEN.needsPicture)
        assertFalse(SessionMode.WORKSPACE.needsPicture)
        assertFalse(SessionMode.REMOTE.needsPicture)
    }

    @Test
    fun aFirstVisitAsksAndLaterVisitsOpenInTheRememberedMode() {
        val memory = SessionModeMemory(MapStore())
        val all = SessionMode.entries
        assertNull(memory.startingMode("mac-1", asksEveryTime = false, available = all))
        memory.remember("mac-1", SessionMode.REMOTE)
        assertEquals(SessionMode.REMOTE, memory.startingMode("mac-1", asksEveryTime = false, available = all))
        assertNull(memory.startingMode("mac-2", asksEveryTime = false, available = all))
    }

    @Test
    fun theSettingThatAlwaysAsksOverridesWhatWasRemembered() {
        val memory = SessionModeMemory(MapStore())
        memory.remember("mac-1", SessionMode.SCREEN)
        assertNull(memory.startingMode("mac-1", asksEveryTime = true, available = SessionMode.entries))
    }

    @Test
    fun aRememberedModeTheComputerNoLongerOffersAsksAgain() {
        val memory = SessionModeMemory(MapStore())
        memory.remember("mac-1", SessionMode.WORKSPACE)
        assertNull(memory.startingMode("mac-1", asksEveryTime = false, available = SessionMode.available(workspaceOffered = false)))
    }

    @Test
    fun aComputerWithoutAnIdIsNeverRemembered() {
        val store = MapStore()
        val memory = SessionModeMemory(store)
        memory.remember(null, SessionMode.REMOTE)
        assertTrue(store.values.isEmpty())
        assertNull(memory.startingMode(null, asksEveryTime = false, available = SessionMode.entries))
    }

    @Test
    fun anUnknownStoredKeyReadsAsNothingRemembered() {
        val store = MapStore().apply { values["session_mode.mac-1"] = "hologram" }
        assertNull(SessionModeMemory(store).remembered("mac-1"))
    }
}
