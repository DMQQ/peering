package pl.dmq.peering.session.files

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.RemoteEntryKind
import pl.dmq.peering.wire.RemoteFileOperation
import pl.dmq.peering.wire.TerminalRequest

class FileChangesTest {
    private val sent = mutableListOf<TerminalRequest>()
    private val entries = mutableListOf(entry("a.txt"), entry("b.txt"), entry("Docs", isDirectory = true))
    private val listings = ScriptedFileHost(folders = mapOf(HOME to entries))
    private lateinit var browser: FileBrowser

    private fun entry(name: String, isDirectory: Boolean = false) = RemoteDirectoryEntry(
        name, isDirectory, isSymlink = false, size = 3, permissions = if (isDirectory) "drwxr-xr-x" else "-rw-r--r--",
    )

    private fun start(changes: ScriptedFileHost = ScriptedFileHost(folders = emptyMap())) {
        browser = FileBrowser(
            supportsFileBrowser = true,
            browserID = SCOPE,
            send = { request ->
                sent += request
                val host = if (request is TerminalRequest.ListDirectory) listings else changes
                host.answer(request).forEach { browser.onEvent(it) }
            },
            writeDownloadRange = { _, _ -> },
        )
        browser.open(HOME)
        sent.clear()
    }

    @Test
    fun createSendsOneOperationAndListsTheFolderAgain() {
        start()
        browser.create("notes.md", RemoteEntryKind.FILE)
        assertEquals(
            listOf(
                TerminalRequest.ChangeFile(SCOPE, RemoteFileOperation.Create("$HOME/notes.md", RemoteEntryKind.FILE)),
                TerminalRequest.ListDirectory(SCOPE, HOME),
            ),
            sent,
        )
        assertTrue(!browser.state.value.changes.isRunning)
    }

    @Test
    fun aNameTheComputerWouldRefuseIsNotSent() {
        start()
        browser.create("a/b", RemoteEntryKind.FOLDER)
        browser.rename(entry("a.txt"), "..")
        browser.rename(entry("a.txt"), "a.txt")
        assertEquals(emptyList<TerminalRequest>(), sent)
    }

    @Test
    fun deletingSeveralEntriesSendsThemOneAtATime() {
        start()
        browser.delete(listOf(entry("a.txt"), entry("b.txt")))
        val changes = sent.filterIsInstance<TerminalRequest.ChangeFile>().map { it.operation }
        assertEquals(listOf(RemoteFileOperation.Delete("$HOME/a.txt"), RemoteFileOperation.Delete("$HOME/b.txt")), changes)
        assertEquals(1, sent.count { it is TerminalRequest.ListDirectory })
    }

    @Test
    fun aRefusedOperationStopsTheRunAndKeepsTheComputersText() {
        val refusing = ScriptedFileHost(folders = emptyMap())
        refusing.refusals["$HOME/a.txt"] = "Not allowed to change that file."
        start(refusing)
        browser.delete(listOf(entry("a.txt"), entry("b.txt")))
        assertEquals("Not allowed to change that file.", browser.state.value.changes.failure)
        assertEquals(1, sent.count { it is TerminalRequest.ChangeFile })
        browser.dismissFailures()
        assertNull(browser.state.value.changes.failure)
    }

    @Test
    fun uploadSendsTheDeclaredSizeThenPiecesAndRefreshes() = runTest {
        start()
        val data = ByteArray(70_000) { (it % 7).toByte() }
        browser.upload("data.bin", data.size.toLong(), data.asList().chunked(32 * 1024).map { it.toByteArray() }.iterator())
        assertEquals(TerminalRequest.BeginWrite(SCOPE, "$HOME/data.bin", 70_000), sent.first())
        assertEquals(3, sent.count { it is TerminalRequest.WriteChunk })
        assertEquals(FileUpload.Done("$HOME/data.bin"), browser.state.value.upload)
        assertTrue(sent.last() is TerminalRequest.ListDirectory)
    }

    @Test
    fun uploadIntoAnotherFolderOpensTheScopeAndWritesThereNotInTheFolderOnScreen() = runTest {
        start()
        browser.uploadInto("/work/app", "shot.jpg", 2, listOf(byteArrayOf(1, 2)).iterator())
        assertEquals(TerminalRequest.StartBrowser(SCOPE), sent[0])
        assertEquals(TerminalRequest.BeginWrite(SCOPE, "/work/app/shot.jpg", 2), sent[1])
        assertEquals(FileUpload.Done("/work/app/shot.jpg"), browser.state.value.upload)
    }

    @Test
    fun aFileOverThePhoneLimitIsRefusedBeforeAnythingIsSent() = runTest {
        start()
        browser.upload("big.bin", TransferLimits.MAXIMUM_PHONE_UPLOAD_BYTES + 1, emptyList<ByteArray>().iterator())
        assertEquals(emptyList<TerminalRequest>(), sent)
        assertEquals(FileUpload.Failed("$HOME/big.bin", UploadFailure.TooLarge), browser.state.value.upload)
    }

    @Test
    fun theComputersWriteRefusalEndsTheUploadAsFailed() = runTest {
        val refusing = ScriptedFileHost(folders = emptyMap())
        refusing.refusals["$HOME/x.txt"] = "No room."
        start(refusing)
        browser.upload("x.txt", 2, listOf(byteArrayOf(1, 2)).iterator())
        assertEquals(FileUpload.Failed("$HOME/x.txt", UploadFailure.Host("No room.")), browser.state.value.upload)
    }

    @Test
    fun anUnreadableSourceFailsTheUpload() = runTest {
        start()
        val broken = object : Iterator<ByteArray> {
            override fun hasNext() = true

            override fun next(): ByteArray = throw java.io.IOException("gone")
        }
        browser.upload("x.txt", 10, broken)
        assertEquals(FileUpload.Failed("$HOME/x.txt", UploadFailure.Unreadable), browser.state.value.upload)
    }

    private companion object {
        const val SCOPE = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        const val HOME = "/Users/me"
    }
}
