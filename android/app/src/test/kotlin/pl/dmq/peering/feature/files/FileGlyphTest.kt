package pl.dmq.peering.feature.files

import org.junit.Assert.assertEquals
import org.junit.Test

class FileGlyphTest {
    @Test
    fun entriesAreToldByKindFirstThenByExtension() {
        assertEquals(FileGlyph.FOLDER, FileGlyph.of(folder("src")))
        assertEquals(FileGlyph.EXECUTABLE, FileGlyph.of(file("run.png", permissions = "-rwxr-xr-x")))
        assertEquals(FileGlyph.IMAGE, FileGlyph.of(file("Photo.JPG")))
        assertEquals(FileGlyph.PDF, FileGlyph.of(file("a.pdf")))
        assertEquals(FileGlyph.ARCHIVE, FileGlyph.of(file("a.tar.gz")))
        assertEquals(FileGlyph.CODE, FileGlyph.of(file("Main.kt")))
        assertEquals(FileGlyph.GENERIC, FileGlyph.of(file("data.bin")))
    }

    @Test
    fun aDotfileHasNoExtension() {
        assertEquals("", FileGlyph.extensionOf(".env"))
        assertEquals("gz", FileGlyph.extensionOf("a.tar.gz"))
        assertEquals(FileGlyph.GENERIC, FileGlyph.byName(".zshrc"))
    }

    @Test
    fun shareTypesFollowTheName() {
        assertEquals("image/png", MimeTypes.of("/a/b.PNG"))
        assertEquals("text/plain", MimeTypes.of("/a/b.swift"))
        assertEquals("application/octet-stream", MimeTypes.of("/a/b"))
    }
}
