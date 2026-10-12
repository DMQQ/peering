package pl.dmq.peering.session.terminal

import pl.dmq.peering.wire.TerminalAttentionKind

/** One shell as the phone shows it. The screen is not here: it changes with every output and is published by `frames`. */
data class TerminalTab(
    val id: String,
    val name: String,
    val isRunning: Boolean,
    val columns: Int,
    val rows: Int,
    val exitStatus: Int? = null,
    val failure: String? = null,
    val attention: TerminalAttentionKind? = null,
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
