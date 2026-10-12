package pl.dmq.peering.feature.agents

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.RemoteDirectoryEntry

class FolderPickerTest {
    private fun folder(name: String) = RemoteDirectoryEntry(name, isDirectory = true, isSymlink = false, size = 0, permissions = "drwxr-xr-x")
    private fun file(name: String) = RemoteDirectoryEntry(name, isDirectory = false, isSymlink = false, size = 1, permissions = "-rw-r--r--")

    private class Harness(scope: CoroutineScope) {
        val requests = mutableListOf<String?>()
        val picker = FolderPicker({ requests += it }, scope)
    }

    private fun listing(path: String, vararg entries: RemoteDirectoryEntry) =
        AgentEvent.Directory(path = path, entries = entries.toList(), truncated = false)

    @Test
    fun openingAsksForTheHomeFolderFirst() = runTest {
        val harness = Harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        harness.picker.open()
        assertEquals(listOf<String?>(null), harness.requests)
        assertTrue(harness.picker.ui.value.isLoading)
    }

    @Test
    fun homeListingIsTheTopAndHasNoParent() = runTest {
        val harness = Harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        harness.picker.open()
        harness.picker.onEvent(listing("/Users/me", folder("Work")))
        val ui = harness.picker.ui.value
        assertEquals("/Users/me", ui.usablePath)
        assertNull(ui.parentPath)
        assertFalse(ui.isLoading)
    }

    @Test
    fun descendingShowsAParentThatStopsAtTheHomeFolder() = runTest {
        val harness = Harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        harness.picker.open()
        harness.picker.onEvent(listing("/Users/me", folder("Work")))
        harness.picker.enter(folder("Work"))
        harness.picker.onEvent(listing("/Users/me/Work"))
        assertEquals("/Users/me", harness.picker.ui.value.parentPath)
        harness.picker.up()
        assertEquals(listOf<String?>(null, "/Users/me/Work", "/Users/me"), harness.requests)
    }

    @Test
    fun foldersAreSortedByNameAndFilesAreLeftOut() = runTest {
        val harness = Harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        harness.picker.open()
        harness.picker.onEvent(listing("/Users/me", file("notes.txt"), folder("beta"), folder("Alpha")))
        assertEquals(listOf("Alpha", "beta"), harness.picker.ui.value.folders.map { it.name })
    }

    @Test
    fun hiddenFoldersNeedTheToggleAndQueryNarrowsTheList() = runTest {
        val harness = Harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        harness.picker.open()
        harness.picker.onEvent(listing("/Users/me", folder(".cache"), folder("Projects"), folder("project-old")))
        assertEquals(listOf("project-old", "Projects"), harness.picker.ui.value.folders.map { it.name })
        harness.picker.setShowsHidden(true)
        assertEquals(listOf(".cache", "project-old", "Projects"), harness.picker.ui.value.folders.map { it.name })
        harness.picker.setQuery("PROJ")
        assertEquals(listOf("project-old", "Projects"), harness.picker.ui.value.folders.map { it.name })
    }

    @Test
    fun failureClearsTheListingAndTheFolderCannotBeChosen() = runTest {
        val harness = Harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        harness.picker.open()
        harness.picker.onEvent(listing("/Users/me", folder("Work")))
        harness.picker.enter(folder("Work"))
        harness.picker.onEvent(AgentEvent.BrowseFailure("/Users/me/Work", "Permission denied"))
        val ui = harness.picker.ui.value
        assertEquals("Permission denied", ui.failure)
        assertTrue(ui.folders.isEmpty())
        assertNull(ui.usablePath)
    }

    @Test
    fun waitingNoteIsShownWhileTheMacAsksForApproval() = runTest {
        val harness = Harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        harness.picker.open()
        harness.picker.onEvent(AgentEvent.BrowseWaiting("/", "Allow access on the Mac"))
        val ui = harness.picker.ui.value
        assertEquals("Allow access on the Mac", ui.waitingNote)
        assertTrue(ui.isLoading)
    }

    @Test
    fun listingThatArrivesWhileIdleIsIgnored() = runTest {
        val harness = Harness(CoroutineScope(UnconfinedTestDispatcher(testScheduler)))
        harness.picker.onEvent(listing("/Users/me", folder("Work")))
        assertNull(harness.picker.ui.value.path)
    }
}
