package pl.dmq.peering.ssh

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.ssh.bridge.SshWireBridge
import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.RemoteEntryKind
import pl.dmq.peering.wire.RemoteFileKind
import pl.dmq.peering.wire.RemoteFileOperation
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.toBase64

@OptIn(ExperimentalCoroutinesApi::class)
class BridgeTest {
    private val connection = FakeConnection()
    private val events = mutableListOf<TerminalEvent>()

    private fun TestScope.bridge() =
        SshWireBridge(connection, this, UnconfinedTestDispatcher(testScheduler)) { events += it }

    private inline fun <reified T : TerminalEvent> events() = events.filterIsInstance<T>()

    @Test
    fun creatingAShellAnnouncesItBeforeAnyOutputCanArrive() = runTest {
        val bridge = bridge()
        bridge.send(TerminalRequest.Create)
        connection.shells.single().onOutput("$ ".encodeToByteArray())
        assertTrue(events[0] is TerminalEvent.Created)
        assertTrue(events[1] is TerminalEvent.Output)
        assertEquals("Shell 1", events<TerminalEvent.Created>().single().terminal.name)
        bridge.close()
    }

    @Test
    fun inputGoesToTheShellItNamesAndResizeReachesTheServer() = runTest {
        val bridge = bridge()
        bridge.send(TerminalRequest.Create)
        val id = events<TerminalEvent.Created>().single().terminal.id
        bridge.send(TerminalRequest.Input(id, "ls\r".encodeToByteArray().toBase64()))
        bridge.send(TerminalRequest.Resize(id, 100, 40))
        val shell = connection.shells.single()
        assertEquals("ls\r", shell.written.toString())
        assertEquals(100 to 40, shell.size)
        bridge.close()
    }

    @Test
    fun inputKeepsTheOrderItWasTypedIn() = runTest {
        val bridge = bridge()
        bridge.send(TerminalRequest.Create)
        val id = events<TerminalEvent.Created>().single().terminal.id
        "echo".forEach { bridge.send(TerminalRequest.Input(id, it.toString().encodeToByteArray().toBase64())) }
        assertEquals("echo", connection.shells.single().written.toString())
        bridge.close()
    }

    @Test
    fun aShellThatEndsReportsItsStatusAndStaysListedUntilClosed() = runTest {
        val bridge = bridge()
        bridge.send(TerminalRequest.Create)
        val id = events<TerminalEvent.Created>().single().terminal.id
        connection.shells.single().onEnd(3)
        assertEquals(3, events<TerminalEvent.Exited>().single().status)
        bridge.send(TerminalRequest.ListTerminals)
        assertFalse(events<TerminalEvent.Snapshot>().single().terminals.single().isRunning)
        bridge.send(TerminalRequest.Close(id))
        assertEquals(id, events<TerminalEvent.Closed>().single().sessionID)
        assertTrue(connection.shells.single().closed)
        bridge.close()
    }

    @Test
    fun aLostConnectionEndsEveryRunningShell() = runTest {
        val bridge = bridge()
        bridge.send(TerminalRequest.Create)
        bridge.send(TerminalRequest.Create)
        bridge.connectionLost()
        assertEquals(2, events<TerminalEvent.Exited>().size)
        bridge.close()
    }

    @Test
    fun theSecondShellIsNamedAfterTheCountAndRenameIsKeptLocally() = runTest {
        val bridge = bridge()
        bridge.send(TerminalRequest.Create)
        bridge.send(TerminalRequest.Create)
        val ids = events<TerminalEvent.Created>().map { it.terminal.id }
        assertEquals("Shell 2", events<TerminalEvent.Created>()[1].terminal.name)
        bridge.send(TerminalRequest.Rename(ids[0], "build"))
        bridge.send(TerminalRequest.ListTerminals)
        assertEquals(listOf("build", "Shell 2"), events<TerminalEvent.Snapshot>().single().terminals.map { it.name })
        bridge.close()
    }

    @Test
    fun aFolderListsFoldersFirstThenByNameAndNamesTheResolvedPath() = runTest {
        connection.sftp.entries = listOf(
            RemoteDirectoryEntry("b.txt", false, false, 1, "-rw-r--r--"),
            RemoteDirectoryEntry("Zeta", true, false, 0, "drwxr-xr-x"),
            RemoteDirectoryEntry("alpha", true, false, 0, "drwxr-xr-x"),
        )
        val bridge = bridge()
        bridge.send(TerminalRequest.ListDirectory("B", null))
        val listing = events<TerminalEvent.Directory>().single()
        assertEquals("/home/me", listing.path)
        assertEquals(listOf("alpha", "Zeta", "b.txt"), listing.entries.map { it.name })
        bridge.close()
    }

    @Test
    fun aDownloadPieceNamesItsOffsetAndTheFilesSize() = runTest {
        connection.sftp.files["/a"] = ByteArray(100_000) { it.toByte() }
        val bridge = bridge()
        bridge.send(TerminalRequest.ReadRange("B", "/a", 32 * 1024))
        val piece = events<TerminalEvent.FileRange>().single()
        assertEquals(32 * 1024L, piece.offset)
        assertEquals(100_000L, piece.totalBytes)
        assertEquals(32 * 1024, piece.dataBytes.size)
        bridge.close()
    }

    @Test
    fun aTextFileIsPreviewedInPiecesTheLastOneMarked() = runTest {
        connection.sftp.files["/notes.txt"] = ByteArray(70_000) { 'a'.code.toByte() }
        val bridge = bridge()
        bridge.send(TerminalRequest.ReadFile("B", "/notes.txt"))
        val pieces = events<TerminalEvent.FileContents>()
        assertEquals(listOf(0L, 65_536L), pieces.map { it.offset })
        assertEquals(listOf(false, true), pieces.map { it.isLast })
        assertTrue(pieces.all { it.kind == RemoteFileKind.TEXT })
        bridge.close()
    }

    @Test
    fun aBinaryFileIsRefusedAPreviewWithASentence() = runTest {
        connection.sftp.files["/blob"] = byteArrayOf(1, 0, 2)
        val bridge = bridge()
        bridge.send(TerminalRequest.ReadFile("B", "/blob"))
        assertTrue(events<TerminalEvent.BrowseFailure>().single().message.contains("Download"))
        bridge.close()
    }

    @Test
    fun anImageIsDrawnByItsNameEvenThoughItsBytesAreBinary() = runTest {
        connection.sftp.files["/p.PNG"] = byteArrayOf(0, 1, 2)
        val bridge = bridge()
        bridge.send(TerminalRequest.ReadFile("B", "/p.PNG"))
        assertEquals(RemoteFileKind.IMAGE, events<TerminalEvent.FileContents>().single().kind)
        bridge.close()
    }

    @Test
    fun aMissingFileIsAFailureNamingIt() = runTest {
        val bridge = bridge()
        bridge.send(TerminalRequest.ReadRange("B", "/gone", 0))
        val failure = events<TerminalEvent.TransferFailure>().single()
        assertEquals("/gone", failure.path)
        assertEquals("No such file", failure.message)
        bridge.close()
    }

    @Test
    fun anUploadIsWrittenInOrderAndConfirmedWithTheSizeOnTheServer() = runTest {
        val bridge = bridge()
        bridge.send(TerminalRequest.BeginWrite("B", "/up", 6))
        bridge.send(TerminalRequest.WriteChunk("B", "/up", "abc".encodeToByteArray().toBase64(), false))
        bridge.send(TerminalRequest.WriteChunk("B", "/up", "def".encodeToByteArray().toBase64(), true))
        assertEquals("abcdef", connection.sftp.uploaded.decodeToString())
        assertEquals(6L, events<TerminalEvent.WroteFile>().single().totalBytes)
        bridge.close()
    }

    @Test
    fun createRenameAndDeleteAreAnsweredWithTheRequestsPathAndTheDeleteNote() = runTest {
        val bridge = bridge()
        bridge.send(TerminalRequest.ChangeFile("B", RemoteFileOperation.Create("/d", RemoteEntryKind.FOLDER)))
        bridge.send(TerminalRequest.ChangeFile("B", RemoteFileOperation.Rename("/d", "e")))
        bridge.send(TerminalRequest.ChangeFile("B", RemoteFileOperation.Delete("/e")))
        assertEquals(listOf("folder /d", "rename /d e", "delete /e"), connection.sftp.calls)
        val done = events<TerminalEvent.FileOperationDone>()
        assertEquals(listOf("/d", "/d", "/e"), done.map { it.path })
        assertEquals("Deleted", done.last().note)
        bridge.close()
    }

    @Test
    fun aFolderDownloadIsDeclinedBecauseSftpHasNoArchive() = runTest {
        val bridge = bridge()
        bridge.send(TerminalRequest.ArchiveFolder("B", "/dir"))
        assertEquals("/dir", events<TerminalEvent.TransferFailure>().single().path)
        bridge.close()
    }
}
