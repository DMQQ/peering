package pl.dmq.peering.session.terminal.screen

/** A run of text drawn in one rendition. */
data class StyledRun(
    val text: String,
    val foreground: TerminalColor = TerminalColor.Default,
    val background: TerminalColor = TerminalColor.Default,
    val bold: Boolean = false,
    val dim: Boolean = false,
)

data class StyledLine(val runs: List<StyledRun>) {
    val text: String get() = runs.joinToString("") { it.text }

    companion object {
        val EMPTY = StyledLine(emptyList())
    }
}

/** What a view needs to draw: scrollback then screen, with the cursor as an index into [lines]. */
data class ScreenSnapshot(
    val lines: List<StyledLine>,
    val cursorLine: Int,
    val cursorColumn: Int,
    val columns: Int,
    val rows: Int,
    val alternateScreen: Boolean,
) {
    companion object {
        val EMPTY = ScreenSnapshot(emptyList(), 0, 0, 80, 24, false)
    }
}

/**
 * The screen behind one terminal. The view only reads [snapshot], so another emulator can stand in for [VtScreen]
 * without the screen or the session code changing.
 */
interface TerminalEmulator {
    val columns: Int
    val rows: Int

    fun feed(bytes: ByteArray)

    fun resize(columns: Int, rows: Int)

    fun snapshot(): ScreenSnapshot

    /** Drops scrollback beyond the newest [keepLines] lines; the screen itself stays. Memory pressure asks for this. */
    fun trimScrollback(keepLines: Int) = Unit
}
