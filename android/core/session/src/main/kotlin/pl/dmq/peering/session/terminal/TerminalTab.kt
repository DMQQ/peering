package pl.dmq.peering.session.terminal

import pl.dmq.peering.wire.TerminalAttentionKind

/** One shell as the phone shows it. [revision] moves whenever its screen changes, so a view knows to redraw. */
data class TerminalTab(
    val id: String,
    val name: String,
    val isRunning: Boolean,
    val columns: Int,
    val rows: Int,
    val exitStatus: Int? = null,
    val failure: String? = null,
    val attention: TerminalAttentionKind? = null,
    val revision: Int = 0,
)

data class TerminalsState(
    val tabs: List<TerminalTab> = emptyList(),
    val selectedID: String? = null,
    /** True once the computer has answered with its list, so an empty list can be told from not knowing yet. */
    val loaded: Boolean = false,
    /** A failure that belongs to no one terminal, such as a shell that could not be started. */
    val failure: String? = null,
) {
    val selected: TerminalTab? get() = tabs.firstOrNull { it.id == selectedID }
}
