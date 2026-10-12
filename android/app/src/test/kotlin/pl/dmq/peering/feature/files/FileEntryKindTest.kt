package pl.dmq.peering.feature.files

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.wire.RemoteDirectoryEntry

class FileEntryKindTest {
    private fun entry(isDirectory: Boolean, isSymlink: Boolean, permissions: String) = RemoteDirectoryEntry(
        name = "n", isDirectory = isDirectory, isSymlink = isSymlink, size = 0, permissions = permissions,
    )

    @Test
    fun foldersAndFoldersThroughALinkAreTold() {
        assertEquals(FileEntryKind.FOLDER, FileEntryKind.of(entry(true, false, "drwxr-xr-x")))
        assertEquals(FileEntryKind.FOLDER_LINK, FileEntryKind.of(entry(true, true, "lrwxr-xr-x")))
    }

    @Test
    fun aLinkToAFileIsALinkEvenWhenItsModeShowsExecute() {
        assertEquals(FileEntryKind.LINK, FileEntryKind.of(entry(false, true, "lrwxr-xr-x")))
    }

    @Test
    fun aRegularExecutableIsMarkedAndAPlainFileIsNot() {
        assertEquals(FileEntryKind.EXECUTABLE, FileEntryKind.of(entry(false, false, "-rwxr-xr-x")))
        assertEquals(FileEntryKind.FILE, FileEntryKind.of(entry(false, false, "-rw-r--r--")))
    }
}
