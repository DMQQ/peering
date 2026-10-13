package pl.dmq.peering.feature.terminal

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import pl.dmq.peering.feature.agents.FolderRecents
import pl.dmq.peering.feature.agents.HubGuidePresenter
import pl.dmq.peering.feature.files.FolderPickerPresenter
import pl.dmq.peering.feature.remote.HubTab
import pl.dmq.peering.feature.remote.ReportHubPage
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
    computerName: String,
    onFiles: (() -> Unit)?,
    folders: FolderPickerPresenter?,
    recents: FolderRecents,
    modifier: Modifier = Modifier,
) {
    val name = rememberUpdatedState(computerName)
    val presenter = remember(sessions, folders, recents) {
        TerminalListPresenter(sessions, preferences.agentHistory, { name.value }, canChooseFolder = folders != null, recents = recents)
    }
    val inShell by presenter.inShell.collectAsState()
    val choosingFolder by presenter.choosingFolder.collectAsState()
    val state by sessions.state.collectAsState()
    val listState = rememberLazyListState()
    LaunchedEffect(sessions, connected) {
        if (connected) {
            sessions.attach()
            sessions.refreshAgents()
        }
    }
    LaunchedEffect(state) { presenter.onState(state) }
    ReportHubPage(HubTab.TERMINALS, atRoot = !inShell && !choosingFolder)
    BackHandler(enabled = inShell, onBack = presenter::back)
    val page = if (inShell) TerminalPageStep.SHELL else if (choosingFolder) TerminalPageStep.FOLDER else TerminalPageStep.LIST
    DepthTransition(state = page, depth = { it.depth }, modifier = modifier, label = "terminalPage") { step ->
        if (step == TerminalPageStep.FOLDER && folders != null) {
            TerminalFolderPage(folders, recents, onChoose = presenter::startIn, onBack = presenter::cancelFolder)
        } else if (step == TerminalPageStep.SHELL) {
            TerminalRoute(
                sessions = sessions,
                preferences = preferences,
                connected = connected,
                onBack = presenter::back,
                canCreate = false,
                onEnded = presenter::back,
            )
        } else {
            TerminalListScreen(sessions, presenter, preferences.agentHistory, guide, listState, connected, onFiles)
        }
    }
}

private enum class TerminalPageStep(val depth: Int) { LIST(0), FOLDER(1), SHELL(1) }
