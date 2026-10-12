package pl.dmq.peering.feature.files

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.files.DirectoryModel
import pl.dmq.peering.session.files.FileBrowserState

class FileListPresenterTest {
    private fun listing(path: String, vararg entries: pl.dmq.peering.wire.RemoteDirectoryEntry, truncated: Boolean = false) =
        DirectoryModel(path = path, entries = entries.toList(), isTruncated = truncated)

    private fun presenter(port: FakeFileBrowsingPort) =
        FileListPresenter(port, CoroutineScope(UnconfinedTestDispatcher()))

    @Test
    fun noListingYetIsLoading() = runTest {
        assertEquals(FileListStatus.LOADING, presenter(FakeFileBrowsingPort()).ui.value.status)
    }

    @Test
    fun aListingShowsItsEntriesAsContent() = runTest {
        val port = FakeFileBrowsingPort(FileBrowserState(listing = listing("/Users/me", file("a.txt"), folder("Docs"))))
        val ui = presenter(port).ui.value
        assertEquals(FileListStatus.CONTENT, ui.status)
        assertEquals(listOf("Docs", "a.txt"), ui.entries.map { it.name })
    }

    @Test
    fun aFolderWithOnlyDotfilesIsEmptyUntilHiddenFilesAreShown() = runTest {
        val port = FakeFileBrowsingPort(FileBrowserState(listing = listing("/Users/me", file(".env"))))
        val presenter = presenter(port)
        assertEquals(FileListStatus.EMPTY, presenter.ui.value.status)
        presenter.toggleHidden()
        assertEquals(FileListStatus.CONTENT, presenter.ui.value.status)
        assertTrue(presenter.ui.value.showsHidden)
    }

    @Test
    fun aFailedListingIsAnErrorWithTheMacsText() = runTest {
        val port = FakeFileBrowsingPort(FileBrowserState(browseFailure = "Permission denied"))
        val ui = presenter(port).ui.value
        assertEquals(FileListStatus.ERROR, ui.status)
        assertEquals("Permission denied", ui.failure)
    }

    @Test
    fun aListingWhileRefreshingKeepsTheOldEntriesOnScreen() = runTest {
        val port = FakeFileBrowsingPort(FileBrowserState(listing = listing("/a", file("old.txt")), listingLoading = true))
        val ui = presenter(port).ui.value
        assertEquals(FileListStatus.CONTENT, ui.status)
        assertTrue(ui.isRefreshing)
        assertEquals(listOf("old.txt"), ui.entries.map { it.name })
    }

    @Test
    fun breadcrumbsAndUpFollowTheListingPath() = runTest {
        val port = FakeFileBrowsingPort(FileBrowserState(listing = listing("/Users/me/Work")))
        val ui = presenter(port).ui.value
        assertEquals(listOf("/", "Users", "me", "Work"), ui.breadcrumbs.map { it.title })
        assertTrue(ui.canGoUp)
    }

    @Test
    fun aRootHasNothingAbove() = runTest {
        val port = FakeFileBrowsingPort(FileBrowserState(listing = listing("/")))
        val presenter = presenter(port)
        assertFalse(presenter.ui.value.canGoUp)
        presenter.up()
        assertTrue(port.calls.isEmpty())
    }

    @Test
    fun sortingReordersWithoutAskingTheMac() = runTest {
        val port = FakeFileBrowsingPort(FileBrowserState(listing = listing("/a", file("small", size = 1), file("big", size = 9))))
        val presenter = presenter(port)
        presenter.setSort(FileSort.SIZE)
        assertEquals(listOf("big", "small"), presenter.ui.value.entries.map { it.name })
        assertTrue(port.calls.isEmpty())
    }

    @Test
    fun truncationIsReportedFromTheListing() = runTest {
        val port = FakeFileBrowsingPort(FileBrowserState(listing = listing("/a", file("x"), truncated = true)))
        assertTrue(presenter(port).ui.value.isTruncated)
    }

    @Test
    fun openingAndNavigatingGoThroughThePort() = runTest {
        val port = FakeFileBrowsingPort(FileBrowserState(listing = listing("/a/b", folder("c"))))
        val presenter = presenter(port)
        presenter.open(presenter.ui.value.entries.single())
        presenter.goTo("/a")
        presenter.refresh()
        presenter.up()
        assertEquals(listOf("openEntry:c", "list:/a", "list:/a/b", "up"), port.calls)
    }
}
