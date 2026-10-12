package pl.dmq.peering.feature.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TextPreviewTest {
    private fun bytes(text: String) = text.toByteArray(Charsets.UTF_8)

    @Test
    fun linesAreSplitWithoutTheTrailingNewline() {
        assertEquals(listOf("one", "two"), TextPreview.lines(bytes("one\ntwo\n")))
    }

    @Test
    fun crlfLineEndingsLoseTheCarriageReturn() {
        assertEquals(listOf("one", "two"), TextPreview.lines(bytes("one\r\ntwo")))
    }

    @Test
    fun anEmptyFileHasNoLines() {
        assertEquals(emptyList<String>(), TextPreview.lines(bytes("")))
    }

    @Test
    fun aBlankLineInTheMiddleIsKept() {
        assertEquals(listOf("a", "", "b"), TextPreview.lines(bytes("a\n\nb\n")))
    }

    @Test
    fun multibyteCharactersAreDecodedWhole() {
        assertEquals(listOf("zażółć", "🙂"), TextPreview.lines(bytes("zażółć\n🙂")))
    }

    @Test
    fun bytesThatAreNotUtf8AreNotText() {
        assertNull(TextPreview.lines(byteArrayOf(0x41, 0xFF.toByte(), 0x42)))
    }
}
