package pl.dmq.peering.feature.files

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.files.DirectoryModel
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.wire.RemoteDirectoryEntry

class FolderPickerPresenterTest {
    private fun port(path: String, vararg names: RemoteDirectoryEntry) =
        FakeFileBrowsingPort(FileBrowserState(listing = DirectoryModel(path, names.toList(), isTruncated = false)))

    private fun presenter(port: FakeFileBrowsingPort) = FolderPickerPresenter(port, CoroutineScope(UnconfinedTestDispatcher()))

    @Test
    fun listsOnlyVisibleFoldersSortedByName() = runTest {
        val picker = presenter(port("/Users/me", file("a.txt"), folder("zeta"), folder(".git"), folder("Alpha")))
        assertEquals(listOf("Alpha", "zeta"), picker.ui.value.folders)
        assertEquals(FileListStatus.CONTENT, picker.ui.value.status)
    }

    @Test
    fun enteringAFolderListsItAndTheFolderOnScreenIsTheChoice() = runTest {
        val port = port("/Users/me", folder("Projects"))
        val picker = presenter(port)
        picker.enter("Projects")
        assertEquals(listOf("list:/Users/me/Projects"), port.calls)
        assertEquals("/Users/me", picker.chosenPath())
    }

    @Test
    fun aFolderWithoutSubfoldersIsEmptyButStillChoosable() = runTest {
        val picker = presenter(port("/Users/me/Empty", file("a.txt")))
        assertEquals(FileListStatus.EMPTY, picker.ui.value.status)
        assertEquals("/Users/me/Empty", picker.chosenPath())
    }

    @Test
    fun upStopsAtTheRootAndWindowsDrivesAreRoots() = runTest {
        val root = presenter(port("/"))
        assertFalse(root.up())
        val drive = port("/C:/Users", folder("me"))
        val picker = presenter(drive)
        assertTrue(picker.up())
        assertEquals(listOf("up"), drive.calls)
        assertEquals(listOf("C:", "Users"), picker.ui.value.breadcrumbs.map { it.title })
    }

    @Test
    fun nothingIsChosenBeforeAListingArrives() = runTest {
        val port = FakeFileBrowsingPort()
        val picker = presenter(port)
        assertNull(picker.chosenPath())
        assertEquals(FileListStatus.LOADING, picker.ui.value.status)
        picker.open("/Users/me")
        assertEquals(listOf("open:/Users/me"), port.calls)
    }
}
