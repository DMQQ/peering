package pl.dmq.peering.feature.terminal

import androidx.compose.ui.graphics.Color
import pl.dmq.peering.session.terminal.screen.TerminalColor

/** The 256-colour palette on the app's dark backdrop. The first sixteen are chosen to read on near black. */
object TerminalPalette {
    private val ansi = longArrayOf(
        0xFF2B2B30, 0xFFFA7366, 0xFF5CD182, 0xFFF7BF59, 0xFF5AA9FF, 0xFFD58CF0, 0xFF5FD4D4, 0xFFD8D8DE,
        0xFF6B6B73, 0xFFFF9A8F, 0xFF86E6A5, 0xFFFFD98A, 0xFF8CC4FF, 0xFFE6B3F7, 0xFF8FE8E8, 0xFFFFFFFF,
    )
    private val cubeSteps = intArrayOf(0, 95, 135, 175, 215, 255)

    fun resolve(color: TerminalColor, default: Color): Color = when (color) {
        TerminalColor.Default -> default
        is TerminalColor.Indexed -> indexed(color.index)
        is TerminalColor.Rgb -> Color(color.red, color.green, color.blue)
    }

    fun indexed(index: Int): Color = when {
        index in ansi.indices -> Color(ansi[index])
        index in 16..231 -> {
            val cube = index - 16
            Color(cubeSteps[cube / 36], cubeSteps[cube / 6 % 6], cubeSteps[cube % 6])
        }
        index in 232..255 -> (8 + (index - 232) * 10).let { Color(it, it, it) }
        else -> Color(ansi[7])
    }
}
