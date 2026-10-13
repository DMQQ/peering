package pl.dmq.peering.feature.terminal

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.terminal.screen.ScreenSnapshot
import pl.dmq.peering.session.terminal.screen.StyledLine
import pl.dmq.peering.session.terminal.screen.StyledRun

class TerminalPrintedTest {
    private fun snapshot(vararg lines: String) =
        ScreenSnapshot.EMPTY.copy(lines = lines.map { StyledLine(listOf(StyledRun(it))) })

    @Test
    fun anEmptyScreenHasPrintedNothing() {
        assertFalse(ScreenSnapshot.EMPTY.hasPrinted())
    }

    @Test
    fun blankLinesAreNotOutput() {
        assertFalse(snapshot("", "   ").hasPrinted())
    }

    @Test
    fun anyTextIsOutput() {
        assertTrue(snapshot("", "$ ").hasPrinted())
    }
}
