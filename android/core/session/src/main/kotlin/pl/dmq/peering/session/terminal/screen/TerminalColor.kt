package pl.dmq.peering.session.terminal.screen

/** A colour a program asked for; the default is left to the screen's theme. */
sealed interface TerminalColor {
    data object Default : TerminalColor

    /** An entry of the 256-colour palette (0 to 7 normal, 8 to 15 bright). */
    data class Indexed(val index: Int) : TerminalColor

    data class Rgb(val red: Int, val green: Int, val blue: Int) : TerminalColor
}
