package pl.dmq.peering.feature.agents

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringAlert
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.SectionLabel

/** The Agents page: the chats on the computer, the conversations it holds, and the dock that starts a new chat. */
@Composable
fun HubScreen(
    presenter: AgentsHubPresenter,
    folders: FolderPicker,
    onBack: () -> Unit,
    onSessionOpened: () -> Unit,
    onChatStarted: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ui by presenter.ui.collectAsState()
    LaunchedEffect(presenter) { presenter.refresh() }
    if (ui.newChat is NewChatStep.ChoosingFolder) {
        BackHandler(onBack = presenter::cancelNewChat)
        FolderPage(
            folders = folders,
            recentFolders = ui.recentFolders,
            onUseFolder = { if (presenter.startInChosenFolder()) onChatStarted() },
            onUseRecent = { if (presenter.startInRecentFolder(it)) onChatStarted() },
            onBack = presenter::cancelNewChat,
            modifier = modifier,
        )
        return
    }
    var guideSeen by rememberSaveable { mutableStateOf(false) }
    var closing by remember { mutableStateOf<SessionCard?>(null) }
    Box(modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
                IconButton(onClick = onBack) {
                    Icon(AppIcons.back, contentDescription = stringResource(R.string.agents_back_to_remote), tint = PeeringColors.ink)
                }
            }
            HubList(
                ui = ui,
                presenter = presenter,
                guideSeen = guideSeen,
                onGuide = { guideSeen = it },
                onClose = { closing = it },
                onSessionOpened = onSessionOpened,
                onChatStarted = onChatStarted,
            )
        }
        if (ui.agents.isNotEmpty()) {
            val selected = ui.agents.firstOrNull { it.id == ui.selectedAgentID }
            HubDock(
                agent = selected,
                canChooseAgent = ui.agents.size > 1,
                onChat = presenter::beginNewChat,
                onChoose = presenter::openAgentPicker,
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
        if (ui.newChat == NewChatStep.ChoosingAgent) {
            BackHandler(onBack = presenter::cancelNewChat)
            AgentPicker(ui.agents, ui.agentUsage, ui.selectedAgentID, presenter::chooseAgent, presenter::cancelNewChat)
        }
    }
    closing?.let { card ->
        PeeringAlert(
            title = stringResource(R.string.agents_close_title, card.title),
            message = stringResource(R.string.agents_close_message),
            confirm = stringResource(R.string.agents_end_chat),
            onConfirm = {
                presenter.closeSession(card.id)
                closing = null
            },
            cancel = stringResource(R.string.agents_cancel),
            onCancel = { closing = null },
            destructive = true,
        )
    }
}

@Composable
private fun HubList(
    ui: HubUi,
    presenter: AgentsHubPresenter,
    guideSeen: Boolean,
    onGuide: (Boolean) -> Unit,
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
    val run: (HistoryEntry) -> Unit = { entry ->
        when (val action = entry.action) {
            is HistoryAction.OpenPaused -> {
                presenter.openSession(action.sessionID)
                onSessionOpened()
            }
            is HistoryAction.Resume -> if (presenter.resume(action.resumableID, anyway = action.openElsewhere)) onChatStarted()
        }
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = if (ui.agents.isEmpty()) 28.dp else 98.dp),
    ) {
        item(key = "heading") { HubHeading(detail, showsHelp = guideSeen, onHelp = { onGuide(false) }) }
        if (!guideSeen) item(key = "guide") { HubGuideCard(onDismiss = { onGuide(true) }, modifier = Modifier.padding(top = 16.dp)) }
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
                        modifier = Modifier.padding(bottom = 10.dp),
                    )
                }
            }
        }
        if (elsewhere.isNotEmpty()) {
            section(key = "elsewhere", label = R.string.agents_active_on_computer, icon = AppIcons.computer) {
                item(key = "elsewhere-card") { HistoryCard(elsewhere, onRun = run) }
            }
        }
        notice(ui, hasChats = ui.sessions.isNotEmpty() || history.isNotEmpty() || elsewhere.isNotEmpty())
        if (history.isNotEmpty()) {
            section(key = "history", label = R.string.agents_history_title, icon = AgentIcons.history) {
                item(key = "history-card") { HistoryCard(history, onRun = run) }
            }
        }
    }
}

private fun LazyListScope.section(key: String, label: Int, icon: ImageVector, content: LazyListScope.() -> Unit) {
    item(key = "$key-label") { SectionHeading(label, icon) }
    content()
}

@Composable
private fun SectionHeading(label: Int, icon: ImageVector) {
    SectionLabel(stringResource(label), icon, modifier = Modifier.padding(top = 20.dp, bottom = 10.dp))
}

private fun LazyListScope.notice(ui: HubUi, hasChats: Boolean) {
    if (ui.agents.isEmpty()) {
        item(key = "no-agents") { NoAgentsNotice() }
    } else if (!hasChats) {
        item(key = "empty") { AgentEmptyState() }
    }
}

@Composable
private fun NoAgentsNotice() {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 20.dp),
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
        modifier = Modifier.padding(top = 34.dp),
    )
}
