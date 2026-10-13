package pl.dmq.peering.feature.terminal

import androidx.compose.ui.graphics.Color
import pl.dmq.peering.session.terminal.screen.TerminalColor

/** The xterm defaults, not the app's palette: `LS_COLORS` and `--color=auto` output is written against these sixteen values. */
object TerminalPalette {
    private val ansi = longArrayOf(
        0xFF000000, 0xFFCD0000, 0xFF00CD00, 0xFFCDCD00, 0xFF0000EE, 0xFFCD00CD, 0xFF00CDCD, 0xFFE5E5E5,
        0xFF7F7F7F, 0xFFFF0000, 0xFF00FF00, 0xFFFFFF00, 0xFF5C5CFF, 0xFFFF00FF, 0xFF00FFFF, 0xFFFFFFFF,
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
