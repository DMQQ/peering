package pl.dmq.peering.feature.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.wire.RemoteDirectoryEntry

class FileGlyphTest {
    private fun file(name: String, modified: Double? = null) = RemoteDirectoryEntry(
        name = name, isDirectory = false, isSymlink = false, size = 1, permissions = "-rw-r--r--", modified = modified,
    )

    @Test
    fun `a plain file is told by its extension in any case`() {
        assertEquals(FileGlyph.IMAGE, FileGlyph.of(file("Photo.JPG")))
        assertEquals(FileGlyph.CODE, FileGlyph.of(file("main.swift")))
        assertEquals(FileGlyph.ARCHIVE, FileGlyph.of(file("backup.tar")))
        assertEquals(FileGlyph.DOCUMENT, FileGlyph.of(file("notes.md")))
    }

    @Test
    fun `an unknown or missing extension is a plain file`() {
        assertEquals(FileGlyph.FILE, FileGlyph.of(file("data.xyz")))
        assertEquals(FileGlyph.FILE, FileGlyph.of(file("Makefile")))
    }

    @Test
    fun `a folder and a link keep their own glyph whatever the name says`() {
        val folder = RemoteDirectoryEntry("pics.png", isDirectory = true, isSymlink = false, size = 0, permissions = "drwxr-xr-x")
        val link = RemoteDirectoryEntry("pics.png", isDirectory = false, isSymlink = true, size = 0, permissions = "lrwxr-xr-x")
        assertEquals(FileGlyph.FOLDER, FileGlyph.of(folder))
        assertEquals(FileGlyph.LINK, FileGlyph.of(link))
    }

    @Test
    fun `modified time moves from the 2001 reference to unix milliseconds`() {
        assertEquals(978_307_200_000L, file("a", modified = 0.0).modifiedEpochMillis())
        assertEquals(978_307_201_000L, file("a", modified = 1.9).modifiedEpochMillis())
        assertNull(file("a").modifiedEpochMillis())
    }
}
