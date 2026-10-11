package pl.dmq.peering.session.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.RemoteFileKind
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.toBase64

class FileBrowserTest {
    private val scope = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    private val sent = mutableListOf<TerminalRequest>()
    private val outbox = ArrayDeque<TerminalRequest>()
    private val written = sortedMapOf<Long, ByteArray>()

    private var host = ScriptedFileHost(folders = emptyMap())
    private val browser = FileBrowser(
        supportsFileBrowser = true,
        browserID = scope,
        send = { outbox.addLast(it) },
        writeDownloadRange = { offset, bytes -> written[offset] = bytes },
    )

    private fun folder(name: String) = RemoteDirectoryEntry(name, isDirectory = true, isSymlink = false, size = 0, permissions = "drwxr-xr-x")

    private fun file(name: String, size: Long = 10) =
        RemoteDirectoryEntry(name, isDirectory = false, isSymlink = false, size = size, permissions = "-rw-r--r--")

    private fun serve() {
        host = ScriptedFileHost(
            folders = mapOf(
                "/Users/me" to listOf(folder("Projects"), file("notes.txt"), file(".env")),
                "/Users/me/Projects" to listOf(file("main.kt")),
            ),
            files = mapOf(
                "/Users/me/notes.txt" to "hello phone".toByteArray(),
                "/Users/me/Projects/big.bin" to ByteArray(100_000) { (it % 251).toByte() },
                "/tmp/archive/Projects.zip" to ByteArray(70_000) { (it % 13).toByte() },
            ),
            archives = mapOf("/Users/me/Projects" to "/tmp/archive/Projects.zip"),
        )
    }

    /** Delivers every queued request to the scripted host and feeds its answers back until nothing is outstanding. */
    private fun pump() {
        while (outbox.isNotEmpty()) {
            val request = outbox.removeFirst()
            sent += request
            host.answer(request).forEach(browser::onEvent)
        }
    }

    @Test
    fun opensTheScopeThenListsTheHomeFolder() {
        serve()
        browser.open()
        pump()
        assertEquals(
            listOf(TerminalRequest.StartBrowser(scope), TerminalRequest.ListDirectory(scope, null)),
            sent,
        )
        val listing = browser.state.value.listing
        assertEquals("/Users/me", listing?.path)
        assertEquals(listOf("Projects", "notes.txt"), listing?.visibleEntries?.map { it.name })
    }

    @Test
    fun nothingIsSentWithoutTheHostsSupport() {
        serve()
        val silent = FileBrowser(supportsFileBrowser = false, browserID = scope, send = { sent += it }, writeDownloadRange = { _, _ -> })
        silent.open()
        silent.preview("/Users/me/notes.txt")
        silent.download("/Users/me/notes.txt")
        silent.up()
        assertEquals(emptyList<TerminalRequest>(), sent)
        assertNull(silent.state.value.listing)
    }

    @Test
    fun openingAFolderListsItAndUpReturnsToTheParent() {
        serve()
        browser.open()
        pump()
        val projects = browser.state.value.listing!!.visibleEntries.first { it.name == "Projects" }
        browser.openEntry(projects)
        pump()
        assertEquals("/Users/me/Projects", browser.state.value.listing?.path)
        assertEquals(listOf("main.kt"), browser.state.value.listing?.visibleEntries?.map { it.name })

        browser.up()
        pump()
        assertEquals("/Users/me", browser.state.value.listing?.path)
    }

    @Test
    fun upAtTheRootSendsNothing() {
        host = ScriptedFileHost(folders = mapOf("/" to listOf(folder("Users"))))
        browser.open("/")
        pump()
        sent.clear()
        browser.up()
        pump()
        assertEquals(emptyList<TerminalRequest>(), sent)
    }

    @Test
    fun hiddenFilesStayOutOfTheListing() {
        serve()
        browser.open()
        pump()
        val names = browser.state.value.listing?.entries?.map { it.name }
        assertTrue(names!!.contains(".env"))
        assertEquals(false, browser.state.value.listing?.visibleEntries?.any { it.name == ".env" })
    }

    @Test
    fun aFailedListingClearsTheFolderAndShowsTheFailure() {
        serve()
        browser.open()
        pump()
        browser.list("/Users/me/Missing")
        pump()
        assertNull(browser.state.value.listing)
        assertEquals("No such folder", browser.state.value.browseFailure)
        assertEquals(false, browser.state.value.listingLoading)
    }

    @Test
    fun aPreviewLoadsTheFileContents() {
        serve()
        browser.open()
        pump()
        browser.preview("/Users/me/notes.txt")
        pump()
        val preview = browser.state.value.preview
        assertEquals("hello phone", preview?.contents?.decodeToString())
        assertEquals(RemoteFileKind.TEXT, preview?.kind)
        assertTrue(preview?.isComplete == true)
        assertEquals(false, preview?.isTruncated)
    }

    @Test
    fun aPreviewThatCannotBeReadShowsItsFailureOnThatFile() {
        serve()
        browser.open()
        pump()
        browser.preview("/Users/me/gone.txt")
        pump()
        assertEquals("Cannot read that file", browser.state.value.preview?.failure)
        assertEquals("/Users/me", browser.state.value.listing?.path)
    }

    @Test
    fun aPieceThatPastesTheCapIsDroppedAndTheFileSaysItWasCut() {
        browser.preview("/Users/me/big.txt")
        sent.clear()
        outbox.clear()
        val half = ByteArray(FilePreview.TEXT_BYTE_LIMIT / 2 + 1)
        val path = "/Users/me/big.txt"
        browser.onEvent(TerminalEvent.FileContents(scope, path, RemoteFileKind.TEXT, 0, 3L * half.size, half.toBase64(), isLast = false))
        browser.onEvent(TerminalEvent.FileContents(scope, path, RemoteFileKind.TEXT, half.size.toLong(), 3L * half.size, half.toBase64(), isLast = false))
        browser.onEvent(TerminalEvent.FileContents(scope, path, RemoteFileKind.TEXT, 2L * half.size, 3L * half.size, half.toBase64(), isLast = true))
        val preview = browser.state.value.preview
        assertEquals(half.size.toLong(), preview?.contents?.size?.toLong())
        assertTrue(preview?.isTruncated == true)
    }

    @Test
    fun aReadFailureNamingTheOpenPreviewIsShownOnThePreview() {
        serve()
        browser.open()
        pump()
        browser.preview("/Users/me/notes.txt")
        browser.onEvent(TerminalEvent.BrowseFailure(scope, "/Users/me/notes.txt", "Permission denied"))
        assertEquals("Permission denied", browser.state.value.preview?.failure)
        assertEquals("/Users/me", browser.state.value.listing?.path)
    }

    @Test
    fun aDownloadAsksForRangedPiecesAndWritesThemAtTheirOffsets() {
        serve()
        browser.open()
        pump()
        sent.clear()
        browser.download("/Users/me/Projects/big.bin")
        pump()
        assertEquals(
            listOf(0L, 32_768L, 65_536L, 98_304L),
            sent.filterIsInstance<TerminalRequest.ReadRange>().map { it.offset },
        )
        assertEquals(FileTransfer.Finished("/Users/me/Projects/big.bin"), browser.state.value.transfer)
        val assembled = written.values.fold(ByteArray(0)) { acc, piece -> acc + piece }
        assertEquals(100_000, assembled.size)
        assertTrue(assembled.contentEquals(ByteArray(100_000) { (it % 251).toByte() }))
    }

    @Test
    fun aFolderDownloadZipsOnTheMacThenReadsTheArchive() {
        serve()
        browser.open()
        pump()
        sent.clear()
        browser.downloadFolder("/Users/me/Projects")
        pump()
        assertEquals(TerminalRequest.ArchiveFolder(scope, "/Users/me/Projects"), sent.first())
        assertEquals("/tmp/archive/Projects.zip", sent.filterIsInstance<TerminalRequest.ReadRange>().first().path)
        assertEquals(FileTransfer.Finished("/Users/me/Projects"), browser.state.value.transfer)
    }

    @Test
    fun aTransferFailureEndsTheDownloadWithTheHostsMessage() {
        serve()
        browser.open()
        pump()
        browser.download("/Users/me/missing.bin")
        pump()
        assertEquals(
            FileTransfer.Failed("/Users/me/missing.bin", DownloadFailure.Transfer("Cannot read that file")),
            browser.state.value.transfer,
        )
    }

    @Test
    fun anEmptyPieceBeforeTheDeclaredSizeIsAShortRead() {
        browser.download("/Users/me/short.bin")
        sent.clear()
        outbox.clear()
        browser.onEvent(TerminalEvent.FileRange(scope, "/Users/me/short.bin", 0, 500, data = ""))
        assertEquals(
            FileTransfer.Failed("/Users/me/short.bin", DownloadFailure.ShortRead),
            browser.state.value.transfer,
        )
        assertTrue(written.isEmpty())
    }

    @Test
    fun aFileOverTheDownloadLimitIsRefusedBeforeAnyPieceIsWritten() {
        browser.download("/Users/me/huge.bin")
        sent.clear()
        outbox.clear()
        val oneOver = TransferLimits.MAXIMUM_DOWNLOAD_BYTES + 1
        browser.onEvent(TerminalEvent.FileRange(scope, "/Users/me/huge.bin", 0, oneOver, data = "AA=="))
        assertEquals(FileTransfer.Failed("/Users/me/huge.bin", DownloadFailure.TooLarge), browser.state.value.transfer)
        assertTrue(written.isEmpty())
        assertEquals(emptyList<TerminalRequest>(), sent)
    }

    @Test
    fun cancellingADownloadIgnoresLaterPieces() {
        serve()
        browser.open()
        pump()
        browser.download("/Users/me/Projects/big.bin")
        browser.cancelDownload()
        outbox.clear()
        browser.onEvent(TerminalEvent.FileRange(scope, "/Users/me/Projects/big.bin", 0, 100_000, data = "AA=="))
        assertEquals(FileTransfer.Idle, browser.state.value.transfer)
        assertTrue(written.isEmpty())
    }

    @Test
    fun eventsForAnotherScopeAreIgnored() {
        browser.onEvent(TerminalEvent.Directory("someone-else", "/", emptyList(), truncated = false))
        assertNull(browser.state.value.listing)
    }
}
