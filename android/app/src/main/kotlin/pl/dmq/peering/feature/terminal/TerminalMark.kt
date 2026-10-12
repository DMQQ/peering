package pl.dmq.peering.feature.terminal

import pl.dmq.peering.session.terminal.TerminalTab
import pl.dmq.peering.wire.TerminalAttentionKind

/** What a tab's leading mark says, and so how its name is tinted. Failure and attention win over the rest. */
enum class TerminalMark { STARTING, PASSWORD, QUESTION, FAILED, RUNNING, STOPPED }

fun terminalMark(tab: TerminalTab, hasOutput: Boolean): TerminalMark = when {
    tab.failure != null -> TerminalMark.FAILED
    !tab.isRunning -> TerminalMark.STOPPED
    tab.attention == TerminalAttentionKind.PASSWORD -> TerminalMark.PASSWORD
    tab.attention != null -> TerminalMark.QUESTION
    !hasOutput -> TerminalMark.STARTING
    else -> TerminalMark.RUNNING
}

/** The history with [command] first, without a repeat of it, cut to [limit] lines. A blank command changes nothing. */
fun List<String>.withCommand(command: String, limit: Int = 20): List<String> {
    val line = command.trim()
    return if (line.isEmpty()) this else (listOf(line) + filterNot { it == line }).take(limit)
}
