package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Test

class FolderRecentsTest {
    @Test
    fun aNewFolderGoesFirstAndAnOldOneIsNotRepeated() {
        val recorded = FolderRecents.recorded(listOf("/a", "/b", "/c"), "/b", limit = 6)
        assertEquals(listOf("/b", "/a", "/c"), recorded)
    }

    @Test
    fun theListKeepsAtMostTheLimitDroppingTheOldest() {
        val recorded = FolderRecents.recorded(listOf("/a", "/b", "/c"), "/d", limit = 3)
        assertEquals(listOf("/d", "/a", "/b"), recorded)
    }

    @Test
    fun aBlankPathChangesNothing() {
        assertEquals(listOf("/a"), FolderRecents.recorded(listOf("/a"), "  ", limit = 6))
    }

    @Test
    fun recordingSavesTheListForItsMacOnly() {
        val store = InMemoryFolderRecentsStore(mapOf("other" to listOf("/x")))
        val recents = FolderRecents(store, "mac", limit = 6)
        recents.record("/work")
        recents.record("/notes")
        assertEquals(listOf("/notes", "/work"), recents.paths.value)
        assertEquals(listOf("/notes", "/work"), store.saved["mac"])
        assertEquals(listOf("/x"), store.saved["other"])
    }

    @Test
    fun aMacsSavedListIsLoadedWhenItsRecentsAreOpened() {
        val store = InMemoryFolderRecentsStore(mapOf("mac" to listOf("/a", "/b", "/c")))
        assertEquals(listOf("/a", "/b"), FolderRecents(store, "mac", limit = 2).paths.value)
    }
}
