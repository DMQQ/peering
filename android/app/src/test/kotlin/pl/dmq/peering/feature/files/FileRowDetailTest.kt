package pl.dmq.peering.feature.files

import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.util.Locale
import pl.dmq.peering.wire.RemoteDirectoryEntry

class FileRowDetailTest {
    private val words = FileRowDetail.KindWords("Symbolic link", "Folder", "File")

    @Before
    fun english() = Locale.setDefault(Locale.US)

    private fun entry(
        size: Long = 0,
        permissions: String = "-rw-r--r--",
        isDirectory: Boolean = false,
        isSymlink: Boolean = false,
    ) = RemoteDirectoryEntry("x", isDirectory, isSymlink, size, permissions)

    @Test
    fun aFileShowsModeSizeAndDate() {
        val detail = FileRowDetail.of(entry(size = 12_345), "Apr 8, 2026", words)
        assertEquals("-rw-r--r--", detail.mode)
        assertEquals(" · 12 KB · Apr 8, 2026", detail.rest)
    }

    @Test
    fun aFolderShowsItsOwnSizeLikeTheIphone() {
        val detail = FileRowDetail.of(entry(size = 704, permissions = "drwxr-xr-x", isDirectory = true), "Apr 8, 2026", words)
        assertEquals(" · 704 B · Apr 8, 2026", detail.rest)
    }

    @Test
    fun aLinkSaysWhatItIsInsteadOfItsPathLength() {
        val detail = FileRowDetail.of(entry(size = 9, permissions = "lrwxr-xr-x", isSymlink = true), null, words)
        assertEquals(" · Symbolic link", detail.rest)
    }

    @Test
    fun noDateLeavesNoTrailingSeparator() {
        assertEquals(" · 0 B", FileRowDetail.of(entry(), null, words).rest)
    }

    @Test
    fun withoutAModeOnlyAWordIsShown() {
        assertEquals(FileRowDetail("", "Folder"), FileRowDetail.of(entry(permissions = "", isDirectory = true), "Apr 8, 2026", words))
        assertEquals(FileRowDetail("", "File"), FileRowDetail.of(entry(permissions = ""), null, words))
        assertEquals(FileRowDetail("", "Symbolic link"), FileRowDetail.of(entry(permissions = "", isSymlink = true), null, words))
    }
}
