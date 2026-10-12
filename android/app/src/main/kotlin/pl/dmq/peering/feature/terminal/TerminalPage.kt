package pl.dmq.peering.feature.terminal

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import pl.dmq.peering.feature.agents.HubGuidePresenter
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.ui.kit.DepthTransition

/**
 * The Terminals tab: the list of shells, and a tapped shell pushed over it with a back arrow. System back leaves the
 * shell for the list; from the list it is left to the caller, which closes the hub.
 */
@Composable
fun TerminalPage(
    sessions: TerminalSessions,
    preferences: TerminalPreferences,
    guide: HubGuidePresenter,
    connected: Boolean,
    onFiles: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val presenter = remember(sessions) { TerminalListPresenter(sessions) }
    val inShell by presenter.inShell.collectAsState()
    val state by sessions.state.collectAsState()
    val listState = rememberLazyListState()
    LaunchedEffect(sessions, connected) {
        if (connected) sessions.attach()
    }
    LaunchedEffect(state) { presenter.onState(state) }
    BackHandler(enabled = inShell, onBack = presenter::back)
    DepthTransition(state = inShell, depth = { if (it) 1 else 0 }, modifier = modifier, label = "terminalPage") { shell ->
        if (shell) {
            TerminalRoute(
                sessions = sessions,
                preferences = preferences,
                connected = connected,
                onBack = presenter::back,
                canCreate = false,
                onEnded = presenter::back,
            )
        } else {
            TerminalListScreen(sessions, presenter, guide, listState, connected, onFiles)
        }
    }
}
