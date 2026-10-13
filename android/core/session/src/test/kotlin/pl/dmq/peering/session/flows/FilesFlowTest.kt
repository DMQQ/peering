package pl.dmq.peering.session.flows

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.files.DownloadFailure
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.session.files.FileTransfer
import pl.dmq.peering.session.files.ScriptedFileHost
import pl.dmq.peering.session.files.TransferLimits
import pl.dmq.peering.session.files.UploadOutcome
import pl.dmq.peering.session.files.UploadPlan
import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.RemoteFileKind
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest

class FilesFlowTest {
    private val scope = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    private val outbox = mutableListOf<TerminalRequest>()
    private val sent = mutableListOf<TerminalRequest>()
    private val written = sortedMapOf<Long, ByteArray>()
    private val host = windowsHost()
    private val browser = FileBrowser(
        supportsFileBrowser = true,
        browserID = scope,
        send = { outbox += it },
        writeDownloadRange = { offset, bytes -> written[offset] = bytes },
    )

    @Test
    fun aWindowsMacListsItsDrivesThenOpensAFolderByName() {
        browser.open("/")
        pump()
        assertEquals(listOf(TerminalRequest.StartBrowser(scope), TerminalRequest.ListDirectory(scope, "/")), sent)
        assertEquals(listOf("C:", "D:"), browser.state.value.listing?.visibleEntries?.map { it.name })

        browser.openEntry(folder("C:"))
        pump()
        browser.openEntry(folder("Users"))
        pump()

        assertEquals("/C:/Users", browser.state.value.listing?.path)
        assertEquals(listOf("me"), browser.state.value.listing?.visibleEntries?.map { it.name })
    }

    @Test
    fun aTextFileOpensInThePreviewWithItsWholeContents() {
        browser.list("/C:/Users/me")
        pump()

        browser.openEntry(file("notes.txt"))
        pump()

        val preview = browser.state.value.preview
        assertEquals("/C:/Users/me/notes.txt", preview?.path)
        assertEquals(RemoteFileKind.TEXT, preview?.kind)
        assertEquals("hello phone", preview?.contents?.decodeToString())
        assertTrue(preview?.isComplete == true)
    }

    @Test
    fun aLargeFileDownloadsInRangedPiecesAndReportsProgressAsEachArrives() {
        browser.list("/C:/Users/me")
        pump()
        val total = BIG_FILE.size.toLong()

        browser.download("/C:/Users/me/big.bin")
        host.answer(outbox.removeAt(0)).forEach(browser::onEvent)

        assertEquals(TransferLimits.DOWNLOAD_CHUNK_BYTES / total.toDouble(), running().plan.progress ?: -1.0, 1e-9)
        pump()

        assertEquals(FileTransfer.Finished("/C:/Users/me/big.bin"), browser.state.value.transfer)
        assertEquals(listOf(0L, 32_768L, 65_536L, 98_304L), written.keys.toList())
        assertArrayEquals(BIG_FILE, written.values.fold(ByteArray(0)) { all, piece -> all + piece })
    }

    @Test
    fun aDownloadTheMacCannotReadEndsWithTheMacsOwnMessage() {
        browser.list("/C:/Users/me")
        pump()

        browser.download("/C:/Users/me/missing.bin")
        pump()

        assertEquals(
            FileTransfer.Failed("/C:/Users/me/missing.bin", DownloadFailure.Transfer("Cannot read that file")),
            browser.state.value.transfer,
        )
    }

    @Test
    fun aListingTheMacCannotReadShowsItsMessageAndNoFolder() {
        browser.list("/C:/Users/me")
        pump()

        browser.list("/C:/Nope")
        pump()

        assertEquals("No such folder", browser.state.value.browseFailure)
        assertNull(browser.state.value.listing)
    }

    @Test
    fun anUploadGoesInChunksAndTheMacConfirmsTheWrite() {
        val upload = UploadHost(readOnly = emptySet())
        val contents = BIG_FILE.copyOf(70_000)

        val outcomes = runUpload(upload, "/C:/Users/me/out.bin", contents)

        assertEquals(listOf<UploadOutcome>(UploadOutcome.Written("/C:/Users/me/out.bin", 70_000)), outcomes)
        assertArrayEquals(contents, upload.written.getValue("/C:/Users/me/out.bin"))
        assertEquals(3, upload.chunksReceived)
    }

    @Test
    fun anUploadTheMacRefusesStopsAtTheRefusalAndSendsNoData() {
        val upload = UploadHost(readOnly = setOf("/C:/Windows/readonly.txt"))

        val outcomes = runUpload(upload, "/C:/Windows/readonly.txt", BIG_FILE.copyOf(70_000))

        assertEquals(listOf<UploadOutcome>(UploadOutcome.Failed("/C:/Windows/readonly.txt", "Access is denied.")), outcomes)
        assertEquals(0, upload.chunksReceived)
    }

    /** Sends each request the browser queued to the scripted Mac and records what went out. */
    private fun pump() {
        while (outbox.isNotEmpty()) {
            val request = outbox.removeAt(0)
            sent += request
            host.answer(request).forEach(browser::onEvent)
        }
    }

    /** Sends the upload's requests one at a time, and stops at the first outcome the Mac reports. */
    private fun runUpload(upload: UploadHost, path: String, contents: ByteArray): List<UploadOutcome> {
        val outcomes = mutableListOf<UploadOutcome>()
        val requests = UploadPlan.requests(scope, path, contents.size.toLong(), pieces(contents)).iterator()
        while (outcomes.isEmpty() && requests.hasNext()) {
            upload.answer(requests.next()).mapNotNull(UploadPlan::outcome).forEach(outcomes::add)
        }
        return outcomes
    }

    private fun pieces(contents: ByteArray): Iterator<ByteArray> {
        val size = TransferLimits.UPLOAD_CHUNK_BYTES
        return (contents.indices step size).map { start ->
            contents.copyOfRange(start, minOf(start + size, contents.size))
        }.iterator()
    }

    private fun running(): FileTransfer.Running = browser.state.value.transfer as FileTransfer.Running

    private fun windowsHost() = ScriptedFileHost(
        home = "/C:/Users/me",
        folders = mapOf(
            "/" to listOf(folder("C:"), folder("D:")),
            "/C:" to listOf(folder("Users")),
            "/C:/Users" to listOf(folder("me")),
            "/C:/Users/me" to listOf(file("notes.txt"), file("big.bin", BIG_FILE.size.toLong())),
            "/C:/Users/me/Projects" to listOf(file("main.kt")),
        ),
        files = mapOf(
            "/C:/Users/me/notes.txt" to "hello phone".toByteArray(),
            "/C:/Users/me/big.bin" to BIG_FILE,
        ),
    )

    private fun folder(name: String) = RemoteDirectoryEntry(name, isDirectory = true, isSymlink = false, size = 0, permissions = "drwxr-xr-x")

    private fun file(name: String, size: Long = 10) =
        RemoteDirectoryEntry(name, isDirectory = false, isSymlink = false, size = size, permissions = "-rw-r--r--")

    /** The Mac's side of an upload: it keeps what each write brings and confirms it at the last piece. */
    private class UploadHost(private val readOnly: Set<String>) {
        val written = mutableMapOf<String, ByteArray>()
        var chunksReceived = 0
            private set
        private val pending = mutableMapOf<String, ByteArrayOutputStream>()

        fun answer(request: TerminalRequest): List<TerminalEvent> = when (request) {
            is TerminalRequest.BeginWrite -> begin(request)
            is TerminalRequest.WriteChunk -> chunk(request)
            else -> emptyList()
        }

        private fun begin(request: TerminalRequest.BeginWrite): List<TerminalEvent> {
            if (request.path in readOnly) {
                return listOf(TerminalEvent.WriteFailure(request.sessionID, request.path, "Access is denied."))
            }
            pending[request.path] = ByteArrayOutputStream()
            return emptyList()
        }

        private fun chunk(request: TerminalRequest.WriteChunk): List<TerminalEvent> {
            chunksReceived += 1
            val buffer = checkNotNull(pending[request.path]) { "no write began for ${request.path}" }
            buffer.write(request.dataBytes)
            if (!request.isLast) return emptyList()
            written[request.path] = buffer.toByteArray()
            pending.remove(request.path)
            return listOf(TerminalEvent.WroteFile(request.sessionID, request.path, buffer.size().toLong()))
        }
    }

    private companion object {
        val BIG_FILE = ByteArray(100_000) { (it % 251).toByte() }
    }
}
