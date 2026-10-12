package pl.dmq.peering.feature.terminal

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.terminal.screen.TerminalColor

class TerminalPaletteTest {
    @Test
    fun theDefaultIsLeftToTheCaller() {
        assertEquals(Color.Red, TerminalPalette.resolve(TerminalColor.Default, Color.Red))
    }

    @Test
    fun theCubeAndTheGreyRampFollowXterm() {
        assertEquals(Color(255, 0, 0), TerminalPalette.indexed(196))
        assertEquals(Color(0, 0, 0), TerminalPalette.indexed(16))
        assertEquals(Color(8, 8, 8), TerminalPalette.indexed(232))
        assertEquals(Color(238, 238, 238), TerminalPalette.indexed(255))
    }

    @Test
    fun trueColourPassesThrough() {
        assertEquals(Color(1, 2, 3), TerminalPalette.resolve(TerminalColor.Rgb(1, 2, 3), Color.Black))
    }
}
