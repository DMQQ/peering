package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalEventTest {
    private val sessionID = "0A1B2C3D-0000-4000-8000-00000000000F"
    private val terminal = """{"id":"$sessionID","name":"zsh","isRunning":true,"columns":120,"rows":40,"createdAt":5.0}"""

    private val cases: List<Pair<String, TerminalEvent>> = listOf(
        """{"snapshot":{"_0":[$terminal]}}""" to TerminalEvent.Snapshot(listOf(WireJson.decodeFromString(terminal))),
        """{"snapshot":{"_0":[]}}""" to TerminalEvent.Snapshot(emptyList()),
        """{"agents":{"installed":["claude","codex"]}}""" to TerminalEvent.Agents(listOf("claude", "codex")),
        """{"created":{"_0":$terminal}}""" to TerminalEvent.Created(WireJson.decodeFromString(terminal)),
        """{"renamed":{"_0":$terminal}}""" to TerminalEvent.Renamed(WireJson.decodeFromString(terminal)),
        """{"output":{"sessionID":"$sessionID","data":"G1sw"}}""" to TerminalEvent.Output(sessionID, "G1sw"),
        """{"attention":{"sessionID":"$sessionID","kind":"password","message":"Password:"}}""" to
            TerminalEvent.Attention(sessionID, TerminalAttentionKind.PASSWORD, "Password:"),
        """{"commandFinished":{"sessionID":"$sessionID","command":"ls","duration":0.5,"exitStatus":0}}""" to
            TerminalEvent.CommandFinished(sessionID, "ls", 0.5, 0),
        """{"commandFinished":{"sessionID":"$sessionID","duration":2.0,"exitStatus":1}}""" to
            TerminalEvent.CommandFinished(sessionID, null, 2.0, 1),
        """{"exited":{"sessionID":"$sessionID","status":0}}""" to TerminalEvent.Exited(sessionID, 0),
        """{"closed":{"sessionID":"$sessionID"}}""" to TerminalEvent.Closed(sessionID),
        """{"directory":{"sessionID":"$sessionID","path":"/Users/me","entries":[],"truncated":false}}""" to
            TerminalEvent.Directory(sessionID, "/Users/me", emptyList(), truncated = false),
        """{"fileContents":{"sessionID":"$sessionID","path":"/a.txt","kind":"text","offset":0,"totalBytes":2,"data":"aGk=","isLast":true}}""" to
            TerminalEvent.FileContents(sessionID, "/a.txt", RemoteFileKind.TEXT, 0, 2, "aGk=", isLast = true),
        """{"fileRange":{"sessionID":"$sessionID","path":"/a.bin","offset":4096,"totalBytes":8192,"data":"AQID"}}""" to
            TerminalEvent.FileRange(sessionID, "/a.bin", 4096, 8192, "AQID"),
        """{"archiveReady":{"sessionID":"$sessionID","folder":"/src","archivePath":"/tmp/src.zip","totalBytes":900}}""" to
            TerminalEvent.ArchiveReady(sessionID, "/src", "/tmp/src.zip", 900),
        """{"transferFailure":{"sessionID":"$sessionID","path":"/a","message":"Too big"}}""" to
            TerminalEvent.TransferFailure(sessionID, "/a", "Too big"),
        """{"browseFailure":{"sessionID":"$sessionID","path":"/root","message":"Denied"}}""" to
            TerminalEvent.BrowseFailure(sessionID, "/root", "Denied"),
        """{"wroteFile":{"sessionID":"$sessionID","path":"/a.txt","totalBytes":11}}""" to TerminalEvent.WroteFile(sessionID, "/a.txt", 11),
        """{"writeFailure":{"sessionID":"$sessionID","path":"/a.txt","message":"Disk full"}}""" to
            TerminalEvent.WriteFailure(sessionID, "/a.txt", "Disk full"),
        """{"fileOperationDone":{"sessionID":"$sessionID","path":"/a","note":"Renamed"}}""" to
            TerminalEvent.FileOperationDone(sessionID, "/a", "Renamed"),
        """{"fileOperationFailure":{"sessionID":"$sessionID","path":"/a","message":"Exists"}}""" to
            TerminalEvent.FileOperationFailure(sessionID, "/a", "Exists"),
        """{"failed":{"message":"No Mac answered"}}""" to TerminalEvent.Failed(null, "No Mac answered"),
        """{"failed":{"sessionID":"$sessionID","message":"Shell exited"}}""" to TerminalEvent.Failed(sessionID, "Shell exited"),
    )

    @Test
    fun everyEventCaseDecodesAndEncodesBackToItsShape() {
        for ((json, event) in cases) {
            assertEquals(json, event, TerminalEvent.parse(json))
            assertTrue("$json vs ${event.toJson()}", jsonEquals(event.toJson(), json))
        }
    }

    @Test
    fun sessionInfoWithoutTheGridDecodesWithEmptyFields() {
        val info = WireJson.decodeFromString<TerminalSessionInfo>("""{"id":"$sessionID","name":"zsh","isRunning":false}""")
        assertNull(info.columns)
        assertNull(info.rows)
        assertNull(info.createdAt)
    }

    @Test
    fun outputBytesDecodeFromBase64() {
        val output = TerminalEvent.parse("""{"output":{"sessionID":"$sessionID","data":"G1sw"}}""") as TerminalEvent.Output
        assertEquals(listOf<Byte>(0x1b, 0x5b, 0x30), output.dataBytes.toList())
    }

    @Test
    fun unknownEventCaseThrows() {
        assertThrows(SwiftEnumException::class.java) { TerminalEvent.parse("""{"teleport":{}}""") }
    }
}
