package pl.dmq.peering.feature.terminal

import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.remember
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.session.terminal.TerminalTab
import pl.dmq.peering.session.terminal.screen.ScreenSnapshot
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

/** Whether the shell has printed anything yet, which tells a starting shell from a running one. */
fun ScreenSnapshot.hasPrinted(): Boolean = lines.any { it.text.isNotBlank() }

/** Changes only when the first output arrives, so a tab does not recompose for every line that follows. */
@Composable
fun rememberHasPrinted(sessions: TerminalSessions, id: String): State<Boolean> {
    val frame = sessions.frames(id).collectAsState()
    return remember(frame) { derivedStateOf { frame.value.hasPrinted() } }
}

/** The history with [command] first, without a repeat of it, cut to [limit] lines. A blank command changes nothing. */
fun List<String>.withCommand(command: String, limit: Int = 20): List<String> {
    val line = command.trim()
    return if (line.isEmpty()) this else (listOf(line) + filterNot { it == line }).take(limit)
}
