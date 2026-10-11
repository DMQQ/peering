package pl.dmq.peering.session.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteFileNameTest {
    @Test
    fun ordinaryNamesAreValid() {
        assertTrue(RemoteFileName.isValid("notes.txt"))
        assertTrue(RemoteFileName.isValid(".gitignore"))
        assertTrue(RemoteFileName.isValid("My Documents"))
        assertTrue(RemoteFileName.isValid("a\$b"))
    }

    @Test
    fun blankDotAndDotDotAreRefused() {
        assertFalse(RemoteFileName.isValid(""))
        assertFalse(RemoteFileName.isValid("   "))
        assertFalse(RemoteFileName.isValid("."))
        assertFalse(RemoteFileName.isValid(".."))
    }

    @Test
    fun aSlashIsRefusedSoARenameCannotMoveAFile() {
        assertFalse(RemoteFileName.isValid("../.ssh/authorized_keys"))
        assertFalse(RemoteFileName.isValid("a/b"))
    }

    @Test
    fun aNulByteIsRefused() {
        assertFalse(RemoteFileName.isValid("a\u0000b"))
    }

    @Test
    fun theLengthLimitCountsUtf8Bytes() {
        assertTrue(RemoteFileName.isValid("a".repeat(255)))
        assertFalse(RemoteFileName.isValid("a".repeat(256)))
        // Each emoji is four bytes, so 64 of them are 256 bytes and 63 are 252.
        assertFalse(RemoteFileName.isValid("\uD83D\uDE00".repeat(64)))
        assertTrue(RemoteFileName.isValid("\uD83D\uDE00".repeat(63)))
    }

    @Test
    fun aFreeNameTakesTheBaseThenTheLowestFreeNumber() {
        assertEquals("New Folder", RemoteFileName.availableName("New Folder", existing = emptyList()))
        assertEquals("New Folder 2", RemoteFileName.availableName("New Folder", existing = listOf("New Folder")))
        assertEquals(
            "New Folder 3",
            RemoteFileName.availableName("New Folder", existing = listOf("New Folder", "New Folder 2")),
        )
    }

    @Test
    fun aDeletedNumberIsReused() {
        assertEquals(
            "New Folder 2",
            RemoteFileName.availableName("New Folder", existing = listOf("New Folder", "New Folder 3")),
        )
    }

    @Test
    fun theNumberLandsBeforeTheExtension() {
        assertEquals(
            "New File 2.txt",
            RemoteFileName.availableName("New File", ".txt", existing = listOf("New File.txt")),
        )
    }

    @Test
    fun availabilityFoldsCaseBecauseTheVolumeIsCaseInsensitive() {
        assertEquals("New Folder 2", RemoteFileName.availableName("New Folder", existing = listOf("new folder")))
    }
}
