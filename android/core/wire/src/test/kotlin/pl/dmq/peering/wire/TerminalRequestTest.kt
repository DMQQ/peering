package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalRequestTest {
    private val sessionID = "0A1B2C3D-0000-4000-8000-00000000000F"

    private val cases: List<Pair<TerminalRequest, String>> = listOf(
        TerminalRequest.ListTerminals to """{"list":{}}""",
        TerminalRequest.ListAgents to """{"agents":{}}""",
        TerminalRequest.Create to """{"create":{}}""",
        TerminalRequest.Input(sessionID, "AQI=") to """{"input":{"sessionID":"$sessionID","data":"AQI="}}""",
        TerminalRequest.Resize(sessionID, 120, 40) to """{"resize":{"sessionID":"$sessionID","columns":120,"rows":40}}""",
        TerminalRequest.Rename(sessionID, "build") to """{"rename":{"sessionID":"$sessionID","name":"build"}}""",
        TerminalRequest.Retitle(sessionID, "npm test") to """{"retitle":{"sessionID":"$sessionID","command":"npm test"}}""",
        TerminalRequest.Close(sessionID) to """{"close":{"sessionID":"$sessionID"}}""",
        TerminalRequest.StartBrowser(sessionID) to """{"startBrowser":{"id":"$sessionID"}}""",
        TerminalRequest.ListDirectory(sessionID, "/Users/me") to
            """{"listDirectory":{"sessionID":"$sessionID","path":"/Users/me"}}""",
        TerminalRequest.ListDirectory(sessionID) to """{"listDirectory":{"sessionID":"$sessionID"}}""",
        TerminalRequest.ReadFile(sessionID, "/a.txt") to """{"readFile":{"sessionID":"$sessionID","path":"/a.txt"}}""",
        TerminalRequest.ReadRange(sessionID, "/a.bin", 65536) to
            """{"readRange":{"sessionID":"$sessionID","path":"/a.bin","offset":65536}}""",
        TerminalRequest.ArchiveFolder(sessionID, "/src") to """{"archiveFolder":{"sessionID":"$sessionID","path":"/src"}}""",
        TerminalRequest.BeginWrite(sessionID, "/a.txt", 11) to
            """{"beginWrite":{"sessionID":"$sessionID","path":"/a.txt","totalBytes":11}}""",
        TerminalRequest.WriteChunk(sessionID, "/a.txt", "aGk=", isLast = true) to
            """{"writeChunk":{"sessionID":"$sessionID","path":"/a.txt","data":"aGk=","isLast":true}}""",
        TerminalRequest.ChangeFile(sessionID, RemoteFileOperation.Delete("/old")) to
            """{"changeFile":{"sessionID":"$sessionID","operation":{"delete":{"path":"/old"}}}}""",
        TerminalRequest.RegisterPushToken("AQID") to """{"registerPushToken":{"_0":"AQID"}}""",
    )

    @Test
    fun everyRequestEncodesToItsSwiftShape() {
        for ((request, json) in cases) {
            assertTrue("$json vs ${request.toJson()}", jsonEquals(request.toJson(), json))
        }
    }

    @Test
    fun everyRequestShapeDecodesToItsCase() {
        for ((request, json) in cases) {
            assertEquals(request, TerminalRequest.parse(json))
        }
    }

    @Test
    fun byteFieldsDecodeFromBase64() {
        val write = TerminalRequest.parse("""{"writeChunk":{"sessionID":"$sessionID","path":"/a","data":"aGk=","isLast":false}}""")
        assertArrayEquals("hi".toByteArray(), (write as TerminalRequest.WriteChunk).dataBytes)
        val token = TerminalRequest.parse("""{"registerPushToken":{"_0":"AQID"}}""") as TerminalRequest.RegisterPushToken
        assertArrayEquals(byteArrayOf(1, 2, 3), token.tokenBytes)
    }

    @Test
    fun unknownRequestCaseThrows() {
        assertThrows(SwiftEnumException::class.java) { TerminalRequest.parse("""{"teleport":{}}""") }
    }
}
