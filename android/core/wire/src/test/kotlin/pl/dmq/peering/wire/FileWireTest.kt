package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class FileWireTest {
    @Test
    fun directoryEntryRoundTripsWithItsModifiedDate() {
        val text = """{"name":"src","isDirectory":true,"isSymlink":false,"size":4096,"permissions":"drwxr-xr-x","modified":812979000.0}"""
        val entry = WireJson.decodeFromString<RemoteDirectoryEntry>(text)
        assertEquals(812979000.0, entry.modified!!, 0.0)
        assertTrue(jsonEquals(WireJson.encodeToString(RemoteDirectoryEntry.serializer(), entry), text))
    }

    @Test
    fun entryWithoutModifiedDateOmitsTheKey() {
        val text = """{"name":"link","isDirectory":false,"isSymlink":true,"size":0,"permissions":"lrwxr-xr-x"}"""
        val entry = WireJson.decodeFromString<RemoteDirectoryEntry>(text)
        assertNull(entry.modified)
        assertTrue(jsonEquals(WireJson.encodeToString(RemoteDirectoryEntry.serializer(), entry), text))
    }

    @Test
    fun executableBitFollowsTheThreeExecuteSlots() {
        assertTrue(entry("-rwxr-xr-x").isExecutable)
        assertTrue(entry("-rw-r-xr--").isExecutable)
        assertTrue(entry("-rw-r--r-x").isExecutable)
        assertTrue(entry("-rwxr-xr-t").isExecutable)
        assertTrue(entry("-rwsr-xr-x").isExecutable)
    }

    @Test
    fun setuidWithoutExecuteIsNotExecutable() {
        assertFalse(entry("-rwSr--r--").isExecutable)
        assertFalse(entry("-rw-r--r--").isExecutable)
    }

    @Test
    fun symlinksDirectoriesAndMalformedModesAreNotExecutable() {
        assertFalse(entry("lrwxr-xr-x").isExecutable)
        assertFalse(entry("drwxr-xr-x").isExecutable)
        assertFalse(entry("-rwxr-xr").isExecutable)
    }

    @Test
    fun everyFileOperationRoundTrips() {
        val cases = listOf(
            RemoteFileOperation.Create("/Users/me/new.txt", RemoteEntryKind.FILE) to
                """{"create":{"path":"/Users/me/new.txt","kind":"file"}}""",
            RemoteFileOperation.Rename("/Users/me/a.txt", "b.txt") to """{"rename":{"path":"/Users/me/a.txt","to":"b.txt"}}""",
            RemoteFileOperation.Delete("/Users/me/old") to """{"delete":{"path":"/Users/me/old"}}""",
        )
        for ((operation, json) in cases) {
            assertEquals(operation, WireJson.decodeFromString(RemoteFileOperationSerializer, json))
            assertTrue(jsonEquals(WireJson.encodeToString(RemoteFileOperationSerializer, operation), json))
        }
    }

    @Test
    fun kindsUseTheSwiftRawValues() {
        for (kind in listOf("text", "image", "svg", "pdf", "video")) {
            val decoded = WireJson.decodeFromString<RemoteFileKind>("\"$kind\"")
            assertEquals("\"$kind\"", WireJson.encodeToString(RemoteFileKind.serializer(), decoded))
        }
        assertThrows(Exception::class.java) { WireJson.decodeFromString<RemoteFileKind>("\"audio\"") }
        assertThrows(SwiftEnumException::class.java) {
            WireJson.decodeFromString(RemoteFileOperationSerializer, """{"move":{}}""")
        }
    }

    private fun entry(permissions: String) = RemoteDirectoryEntry(
        name = "x",
        isDirectory = false,
        isSymlink = false,
        size = 0,
        permissions = permissions,
        modified = null,
    )
}
