package pl.dmq.peering.session.terminal.screen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VtScreenTest {
    private fun VtScreen.write(text: String) = feed(text.toByteArray(Charsets.UTF_8))

    private fun VtScreen.texts(): List<String> = snapshot().lines.map { it.text }

    @Test
    fun plainTextLandsOnTheFirstRowAndMovesTheCursor() {
        val screen = VtScreen(10, 3)
        screen.write("hello")
        assertEquals(listOf("hello"), screen.texts())
        assertEquals(5, screen.snapshot().cursorColumn)
    }

    @Test
    fun carriageReturnAndLineFeedStartANewLine() {
        val screen = VtScreen(10, 3)
        screen.write("ab\r\ncd")
        assertEquals(listOf("ab", "cd"), screen.texts())
    }

    @Test
    fun writingPastTheLastColumnWrapsOnTheNextCharacter() {
        val screen = VtScreen(4, 3)
        screen.write("abcd")
        assertEquals(listOf("abcd"), screen.texts())
        screen.write("e")
        assertEquals(listOf("abcd", "e"), screen.texts())
    }

    @Test
    fun scrolledOffRowsGoToScrollbackAhead() {
        val screen = VtScreen(5, 2)
        screen.write("1\r\n2\r\n3")
        assertEquals(listOf("1", "2", "3"), screen.texts())
        assertEquals(2, screen.snapshot().cursorLine)
    }

    @Test
    fun cursorPositioningOverwritesInPlace() {
        val screen = VtScreen(10, 3)
        screen.write("xxxxx\u001B[1;2Hab")
        assertEquals(listOf("xabxx"), screen.texts())
    }

    @Test
    fun hugeCursorParametersAreClampedToTheGrid() {
        val screen = VtScreen(10, 3)
        screen.write("\u001B[99999999;99999999Hz")
        val snapshot = screen.snapshot()
        assertEquals(2, snapshot.cursorLine)
        assertEquals("z", snapshot.lines.last().text.trim())
    }

    @Test
    fun eraseInLineClearsFromTheCursor() {
        val screen = VtScreen(10, 3)
        screen.write("abcdef\u001B[1;4H\u001B[K")
        assertEquals(listOf("abc"), screen.texts())
    }

    @Test
    fun eraseDisplayClearsEverythingAndHomesTheCursor() {
        val screen = VtScreen(10, 3)
        screen.write("one\r\ntwo\u001B[2J")
        assertEquals(0, screen.snapshot().cursorLine)
        assertTrue(screen.snapshot().lines.all { it.runs.isEmpty() })
    }

    @Test
    fun colourSurvivesAsARun() {
        val screen = VtScreen(10, 3)
        screen.write("a\u001B[31mb\u001B[0mc")
        val runs = screen.snapshot().lines.single().runs
        assertEquals(listOf("a", "b", "c"), runs.map { it.text })
        assertEquals(TerminalColor.Indexed(1), runs[1].foreground)
        assertEquals(TerminalColor.Default, runs[2].foreground)
    }

    @Test
    fun extendedColourIsOneColourInBothForms() {
        val screen = VtScreen(10, 3)
        screen.write("\u001B[38;5;208mx\u001B[48:2:1:2:3my")
        val runs = screen.snapshot().lines.single().runs
        assertEquals(TerminalColor.Indexed(208), runs[0].foreground)
        assertEquals(TerminalColor.Rgb(1, 2, 3), runs[1].background)
        assertEquals(TerminalColor.Indexed(208), runs[1].foreground)
    }

    @Test
    fun anOutOfRangeExtendedColourIsStepOverNotRead() {
        val screen = VtScreen(10, 3)
        screen.write("\u001B[38;5;999;1mx")
        val run = screen.snapshot().lines.single().runs.single()
        assertEquals(TerminalColor.Default, run.foreground)
        assertTrue(run.bold)
    }

    @Test
    fun alternateScreenClearsOnEntryAndRestoresNothingOfItsRows() {
        val screen = VtScreen(10, 3)
        screen.write("shell\u001B[?1049h")
        assertTrue(screen.snapshot().alternateScreen)
        screen.write("top\r\n1\r\n2\r\n3")
        screen.write("\u001B[?1049l")
        assertEquals(listOf<String>(), screen.texts().filter { it.isNotEmpty() })
    }

    @Test
    fun aMultiByteCharacterSplitAcrossFeedsIsOneCharacter() {
        val screen = VtScreen(10, 3)
        val bytes = "é".toByteArray(Charsets.UTF_8)
        screen.feed(byteArrayOf(bytes[0]))
        screen.feed(byteArrayOf(bytes[1]))
        assertEquals(listOf("é"), screen.texts())
    }

    @Test
    fun anEscapeSequenceSplitAcrossFeedsStillApplies() {
        val screen = VtScreen(10, 3)
        screen.write("a\u001B[3")
        screen.write("1mb")
        assertEquals(TerminalColor.Indexed(1), screen.snapshot().lines.single().runs.last().foreground)
    }

    @Test
    fun oscStringsAreSwallowed() {
        val screen = VtScreen(20, 3)
        screen.write("\u001B]0;title\u0007ok")
        assertEquals(listOf("ok"), screen.texts())
    }

    @Test
    fun shrinkingBelowTheCursorScrollsRowsIntoHistory() {
        val screen = VtScreen(5, 4)
        screen.write("a\r\nb\r\nc\r\nd")
        screen.resize(5, 2)
        assertEquals(listOf("a", "b", "c", "d"), screen.texts())
        assertEquals(2, screen.rows)
    }

    @Test
    fun growingKeepsTheCells() {
        val screen = VtScreen(3, 2)
        screen.write("ab")
        screen.resize(6, 4)
        assertEquals(listOf("ab"), screen.texts())
    }

    @Test
    fun scrollbackIsBounded() {
        val screen = VtScreen(5, 2)
        repeat(3_000) { screen.write("x\r\n") }
        assertTrue(screen.snapshot().lines.size <= 2_002)
    }
}
