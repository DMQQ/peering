package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import pl.dmq.peering.feature.remote.belowHubSwitcher
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.HubDockMetrics
import pl.dmq.peering.feature.agents.HubGuidePresenter
import pl.dmq.peering.feature.agents.HubHeading
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.session.terminal.TerminalTab

/** The Terminals tab as the iPhone draws it: heading, the guide until read, one window card per shell, and the dock. */
@Composable
fun TerminalListScreen(
    sessions: TerminalSessions,
    presenter: TerminalListPresenter,
    guide: HubGuidePresenter,
    listState: LazyListState,
    connected: Boolean,
    onFiles: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val state by sessions.state.collectAsState()
    val cards = remember(state.tabs) { TerminalListPresenter.cards(state) }
    var renaming by remember { mutableStateOf<TerminalTab?>(null) }
    var ending by remember { mutableStateOf<TerminalTab?>(null) }
    fun tab(id: String) = state.tabs.firstOrNull { it.id == id }
    val bottom = HubDockMetrics.clearance + WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    Box(modifier.fillMaxSize()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().belowHubSwitcher(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = bottom),
        ) {
            item(key = "heading") {
                HubHeading(
                    detail = stringResource(R.string.terminal_list_detail),
                    showsHelp = guide.offersHelp,
                    onHelp = guide::reopen,
                    title = stringResource(R.string.terminal_list_title),
                )
            }
            if (guide.visible) item(key = "guide") { TerminalGuideCard(onDismiss = guide::dismiss) }
            when {
                !state.loaded -> item(key = "loading") { TerminalLoading(waitingForConnection = !connected) }
                cards.isEmpty() -> item(key = "empty") { TerminalEmptyBlock() }
                else -> items(cards, key = { it.id }) { card ->
                    TerminalWindowCard(
                        sessions = sessions,
                        card = card,
                        onOpen = { presenter.open(card.id) },
                        onRename = { renaming = tab(card.id) },
                        onEnd = { ending = tab(card.id) },
                        modifier = Modifier.animateItem(),
                    )
                }
            }
        }
        TerminalDock(
            onNew = presenter::create,
            newEnabled = connected,
            onFiles = onFiles,
            modifier = Modifier.align(Alignment.BottomCenter),
        )
    }
    renaming?.let { tab ->
        RenameTerminalDialog(tab, onCancel = { renaming = null }, onSave = {
            presenter.rename(tab.id, it)
            renaming = null
        })
    }
    ending?.let { tab ->
        EndTerminalPrompt(tab, onKeep = { ending = null }, onEnd = {
            presenter.end(tab.id)
            ending = null
        })
    }
}
