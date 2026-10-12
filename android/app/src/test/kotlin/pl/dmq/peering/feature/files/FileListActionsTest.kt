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
import pl.dmq.peering.session.files.FileChanges
import pl.dmq.peering.session.files.FileUpload
import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.RemoteEntryKind
import pl.dmq.peering.wire.RemoteFileOperation

class FileListActionsTest {
    private fun listing(vararg entries: RemoteDirectoryEntry) = DirectoryModel("/Users/me", entries.toList(), isTruncated = false)

    private fun port(vararg entries: RemoteDirectoryEntry, state: FileBrowserState? = null) =
        FakeFileBrowsingPort(state ?: FileBrowserState(listing = listing(*entries)))

    private fun presenter(port: FakeFileBrowsingPort) = FileListPresenter(port, CoroutineScope(UnconfinedTestDispatcher()))

    @Test
    fun searchNarrowsTheRowsWithoutAskingTheComputer() = runTest {
        val port = port(file("report.pdf"), file("notes.txt"), folder("Reports"))
        val presenter = presenter(port)
        presenter.setQuery("REPORT")
        assertEquals(listOf("Reports", "report.pdf"), presenter.ui.value.entries.map { it.name })
        presenter.setQuery("zzz")
        assertEquals(FileListStatus.NO_MATCH, presenter.ui.value.status)
        assertTrue(port.calls.isEmpty())
    }

    @Test
    fun rowsCarryTheirIconKindAndADate() = runTest {
        val presenter = presenter(port(file("a.md", modified = 0.0), file("b.kt"), folder("c")))
        val rows = presenter.ui.value.entries.associateBy { it.name }
        assertEquals(FileGlyph.MARKDOWN, rows.getValue("a.md").glyph)
        assertEquals(FileGlyph.CODE, rows.getValue("b.kt").glyph)
        assertEquals(FileGlyph.FOLDER, rows.getValue("c").glyph)
        assertEquals(978_307_200_000L, rows.getValue("a.md").modifiedEpochMillis)
        assertNull(rows.getValue("b.kt").modifiedEpochMillis)
    }

    @Test
    fun longPressStartsASelectionAndATapThenTogglesInsteadOfOpening() = runTest {
        val port = port(file("a"), file("b"))
        val presenter = presenter(port)
        presenter.toggleSelected(presenter.ui.value.entries.first())
        assertTrue(presenter.ui.value.isSelecting)
        presenter.tap(presenter.ui.value.entries.last())
        assertEquals(2, presenter.ui.value.selectedCount)
        presenter.tap(presenter.ui.value.entries.last())
        assertEquals(1, presenter.ui.value.selectedCount)
        assertTrue(port.calls.none { it.startsWith("openEntry") })
        presenter.clearSelection()
        assertFalse(presenter.ui.value.isSelecting)
    }

    @Test
    fun theSelectionIsForgottenWhenAnotherFolderIsShown() = runTest {
        val port = port(file("a"))
        val presenter = presenter(port)
        presenter.toggleSelected(presenter.ui.value.entries.single())
        port.browser.value = FileBrowserState(listing = DirectoryModel("/Users/me/other", listOf(file("a")), false))
        assertEquals(0, presenter.ui.value.selectedCount)
    }

    @Test
    fun newFolderOffersAFreeNameThenCreatesIt() = runTest {
        val port = port(folder("New Folder"))
        val presenter = presenter(port)
        presenter.beginCreate(RemoteEntryKind.FOLDER)
        assertEquals("New Folder 2", (presenter.ui.value.dialog as FileDialog.Name).text)
        presenter.confirmName()
        assertEquals(listOf("create:New Folder 2:FOLDER"), port.calls)
        assertNull(presenter.ui.value.dialog)
    }

    @Test
    fun aNewFileGetsATextExtension() = runTest {
        val presenter = presenter(port(file("New File.txt")))
        presenter.beginCreate(RemoteEntryKind.FILE)
        assertEquals("New File 2.txt", (presenter.ui.value.dialog as FileDialog.Name).text)
    }

    @Test
    fun aBadOrTakenNameKeepsTheDialogOpenWithAReason() = runTest {
        val port = port(file("taken.txt"))
        val presenter = presenter(port)
        presenter.beginCreate(RemoteEntryKind.FILE)
        presenter.editName("a/b")
        presenter.confirmName()
        assertEquals(FileDialog.NameProblem.INVALID, (presenter.ui.value.dialog as FileDialog.Name).problem)
        presenter.editName("TAKEN.txt")
        presenter.confirmName()
        assertEquals(FileDialog.NameProblem.TAKEN, (presenter.ui.value.dialog as FileDialog.Name).problem)
        assertTrue(port.calls.isEmpty())
    }

    @Test
    fun renameKeepsItsOwnNameAvailableAndSendsTheNewOne() = runTest {
        val port = port(file("a.txt"))
        val presenter = presenter(port)
        presenter.beginRename(presenter.ui.value.entries.single().entry)
        presenter.editName("b.txt")
        presenter.confirmName()
        assertEquals(listOf("rename:a.txt->b.txt"), port.calls)
    }

    @Test
    fun deleteWaitsForConfirmationAndNamesFolders() = runTest {
        val port = port(file("a"), folder("d"))
        val presenter = presenter(port)
        presenter.selectAll()
        presenter.beginDeleteSelected()
        val dialog = presenter.ui.value.dialog as FileDialog.ConfirmDelete
        assertTrue(dialog.includesFolder)
        assertTrue(port.calls.isEmpty())
        presenter.confirmDelete()
        assertEquals(listOf("delete:d,a"), port.calls)
        assertEquals(0, presenter.ui.value.selectedCount)
    }

    @Test
    fun cancellingADialogSendsNothing() = runTest {
        val port = port(file("a"))
        val presenter = presenter(port)
        presenter.beginDelete(listOf(file("a")))
        presenter.dismissDialog()
        assertNull(presenter.ui.value.dialog)
        assertTrue(port.calls.isEmpty())
    }

    @Test
    fun changesAreOffWhileOneIsRunningOrTheLinkIsDown() = runTest {
        val running = FileBrowserState(
            listing = listing(file("a")),
            changes = FileChanges(queue = listOf(RemoteFileOperation.Delete("/Users/me/a"))),
        )
        val port = port(state = running)
        val presenter = presenter(port)
        assertFalse(presenter.ui.value.canChange)
        port.browser.value = FileBrowserState(listing = listing(file("a")))
        assertTrue(presenter.ui.value.canChange)
        port.connected.value = false
        assertFalse(presenter.ui.value.canChange)
        assertTrue(presenter.ui.value.isOffline)
    }

    @Test
    fun noListingAndNoLinkIsOfflineNotLoading() = runTest {
        val port = port(state = FileBrowserState())
        port.connected.value = false
        assertEquals(FileListStatus.OFFLINE, presenter(port).ui.value.status)
    }

    @Test
    fun theLinkComingBackReopensTheFolderOnScreen() = runTest {
        val port = port(file("a"))
        presenter(port)
        port.connected.value = false
        port.connected.value = true
        assertEquals(listOf("open:/Users/me"), port.calls)
    }

    @Test
    fun failuresAreClassifiedFromTheComputersText() = runTest {
        val port = port(state = FileBrowserState(browseFailure = "Peering is not allowed to change that file."))
        assertEquals(FileFailureKind.PERMISSION_DENIED, presenter(port).ui.value.failureKind)
        assertEquals(FileFailureKind.NOT_FOUND, FileFailureKind.of("That folder is no longer there."))
        assertEquals(FileFailureKind.OTHER, FileFailureKind.of("Disk on fire"))
    }

    @Test
    fun downloadingAFolderAsksForAZipDestinationThenFetchesIt() = runTest {
        val port = port(folder("Projects"))
        val presenter = presenter(port)
        presenter.download(presenter.ui.value.entries.single())
        val asked = presenter.destination.request.value
        assertEquals(DestinationRequest("/Users/me/Projects", "Projects.zip", isFolder = true), asked)
        presenter.destination.chosen("content://tree/doc")
        assertEquals(listOf("download:/Users/me/Projects->content://tree/doc:folder"), port.calls)
        assertNull(presenter.destination.request.value)
    }

    @Test
    fun backingOutOfTheSaveDialogStartsNothing() = runTest {
        val port = port(file("a.txt"))
        val presenter = presenter(port)
        presenter.download(presenter.ui.value.entries.single())
        presenter.destination.chosen(null)
        assertTrue(port.calls.isEmpty())
    }

    @Test
    fun uploadProgressAndTheFailureShowUpInTheList() = runTest {
        val port = port(state = FileBrowserState(listing = listing(), upload = FileUpload.Running("/Users/me/x", 5, 10)))
        val presenter = presenter(port)
        assertEquals(0.5, (presenter.ui.value.upload as FileUpload.Running).fraction, 0.0)
        assertFalse(presenter.ui.value.canChange)
        presenter.upload(listOf("content://a", "content://b"))
        presenter.cancelUpload()
        assertEquals(listOf("upload:content://a,content://b", "cancelUpload"), port.calls)
    }
}
