package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.SectionLabel

@Composable
internal fun HubList(
    ui: HubUi,
    presenter: AgentsHubPresenter,
    guide: HubGuidePresenter,
    onClose: (SessionCard) -> Unit,
    onSessionOpened: () -> Unit,
    onChatStarted: () -> Unit,
) {
    val open = ui.sessions.count { it.state != SessionCardState.ENDED && it.state != SessionCardState.FAILED }
    val detail = if (open > 0) {
        pluralStringResource(R.plurals.agents_open_on_computer, open, open)
    } else {
        stringResource(R.string.agents_detail_idle)
    }
    val history = remember(ui.history, ui.resumable) { HubHistory.entries(ui) }
    val elsewhere = remember(ui.resumable) { HubHistory.activeOnComputer(ui) }
    val run: (HistoryEntry) -> Unit = remember(presenter, onSessionOpened, onChatStarted) {
        { entry ->
            when (val action = entry.action) {
                is HistoryAction.OpenPaused -> {
                    presenter.openSession(action.sessionID)
                    onSessionOpened()
                }
                is HistoryAction.Resume -> if (presenter.resume(action.resumableID, anyway = action.openElsewhere)) onChatStarted()
            }
        }
    }
    val bottom = (if (ui.agents.isEmpty()) 28.dp else HubDockMetrics.clearance) +
        WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val hasChats = ui.sessions.isNotEmpty() || history.isNotEmpty() || elsewhere.isNotEmpty()
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = bottom),
    ) {
        item(key = "heading") { HubHeading(detail, showsHelp = guide.offersHelp, onHelp = guide::reopen) }
        if (guide.visible) item(key = "guide") { HubGuideCard(onDismiss = guide::dismiss) }
        if (ui.sessions.isNotEmpty()) {
            section(key = "chats", label = R.string.agents_chats_title, icon = AgentIcons.chats) {
                items(ui.sessions, key = { it.id }) { card ->
                    SessionCardRow(
                        card = card,
                        onOpen = {
                            presenter.openSession(card.id)
                            onSessionOpened()
                        },
                        onNewChatHere = {
                            presenter.newChatHere(card.id)
                            onChatStarted()
                        },
                        onPause = { presenter.endSession(card.id) },
                        onClose = { onClose(card) },
                    )
                }
            }
        }
        if (elsewhere.isNotEmpty()) {
            section(key = "elsewhere", label = R.string.agents_active_on_computer, icon = AppIcons.computer) {
                item(key = "elsewhere-card") { HistoryCard(elsewhere, onRun = run) }
            }
        }
        notice(ui, hasChats)
        if (history.isNotEmpty()) {
            section(key = "history", label = R.string.agents_history_title, icon = AgentIcons.history) {
                item(key = "history-card") { HistoryCard(history, onRun = run) }
            }
        }
    }
}

private fun LazyListScope.section(key: String, label: Int, icon: ImageVector, content: LazyListScope.() -> Unit) {
    item(key = "$key-label") { SectionLabel(stringResource(label), icon, modifier = Modifier.padding(top = 12.dp)) }
    content()
}

private fun LazyListScope.notice(ui: HubUi, hasChats: Boolean) {
    when {
        ui.agents.isEmpty() -> item(key = "no-agents") { NoAgentsNotice() }
        hasChats -> Unit
        ui.loading -> item(key = "loading") { HubLoadingRows() }
        else -> item(key = "empty") { AgentEmptyState() }
    }
}

@Composable
private fun NoAgentsNotice() {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconTile(AppIcons.sparkles)
        Text(stringResource(R.string.agents_none_found), style = PeeringText.caption, color = PeeringColors.muted, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun AgentEmptyState() {
    EmptyState(
        icon = null,
        title = stringResource(R.string.agents_empty_title),
        body = stringResource(R.string.agents_empty_hub_body),
        mascot = true,
        modifier = Modifier.padding(top = 40.dp),
    )
}
