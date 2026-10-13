package pl.dmq.peering.feature.terminal

import androidx.annotation.StringRes
import pl.dmq.peering.R

/** A key written in the notation a shell prints, with what it sends. */
data class TerminalKeySpec(val title: String, @StringRes val label: Int, val bytes: String)

data class TerminalKeyGroup(@StringRes val title: Int, val keys: List<TerminalKeySpec>)

/** The keys of the deck and of the sheet behind its ellipsis. The bytes are what a shell reads on any machine. */
object TerminalKeySpecs {
    val escape = TerminalKeySpec("esc", R.string.terminal_key_escape, "\u001B")
    val tab = TerminalKeySpec("tab", R.string.terminal_key_tab, "\t")
    val interrupt = TerminalKeySpec("⌃C", R.string.terminal_key_interrupt, "\u0003")

    /** Left, up, down, right: the order of the joined group. */
    val arrows = listOf(
        TerminalKeySpec("←", R.string.terminal_key_left, "\u001B[D"),
        TerminalKeySpec("↑", R.string.terminal_key_up, "\u001B[A"),
        TerminalKeySpec("↓", R.string.terminal_key_down, "\u001B[B"),
        TerminalKeySpec("→", R.string.terminal_key_right, "\u001B[C"),
    )

    val groups = listOf(
        TerminalKeyGroup(
            R.string.terminal_group_move,
            listOf(
                TerminalKeySpec("⌥←", R.string.terminal_key_word_left, "\u001Bb"),
                TerminalKeySpec("⌥→", R.string.terminal_key_word_right, "\u001Bf"),
                TerminalKeySpec("⌃A", R.string.terminal_key_line_start, "\u0001"),
                TerminalKeySpec("⌃E", R.string.terminal_key_line_end, "\u0005"),
            ),
        ),
        TerminalKeyGroup(
            R.string.terminal_group_delete,
            listOf(
                TerminalKeySpec("⌫", R.string.terminal_key_backspace, "\u007F"),
                TerminalKeySpec("del", R.string.terminal_key_delete_forward, "\u001B[3~"),
                TerminalKeySpec("⌃W", R.string.terminal_key_delete_word, "\u0017"),
                TerminalKeySpec("⌃U", R.string.terminal_key_delete_to_start, "\u0015"),
                TerminalKeySpec("⌃K", R.string.terminal_key_delete_to_end, "\u000B"),
            ),
        ),
        TerminalKeyGroup(
            R.string.terminal_group_shell,
            listOf(
                TerminalKeySpec("⌃D", R.string.terminal_key_end_of_input, "\u0004"),
                TerminalKeySpec("⌃Z", R.string.terminal_key_suspend, "\u001A"),
                TerminalKeySpec("⌃L", R.string.terminal_key_clear, "\u000C"),
                TerminalKeySpec("⌃R", R.string.terminal_key_search_history, "\u0012"),
                TerminalKeySpec("⇧tab", R.string.terminal_key_back_tab, "\u001B[Z"),
            ),
        ),
        TerminalKeyGroup(
            R.string.terminal_group_pages,
            listOf(
                TerminalKeySpec("home", R.string.terminal_key_home, "\u001B[H"),
                TerminalKeySpec("end", R.string.terminal_key_end, "\u001B[F"),
                TerminalKeySpec("pg↑", R.string.terminal_key_page_up, "\u001B[5~"),
                TerminalKeySpec("pg↓", R.string.terminal_key_page_down, "\u001B[6~"),
                TerminalKeySpec("ins", R.string.terminal_key_insert, "\u001B[2~"),
            ),
        ),
    )
}
