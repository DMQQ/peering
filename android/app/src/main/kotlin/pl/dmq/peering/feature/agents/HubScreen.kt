package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.kit.TitleBarScreen
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.PeeringColors

/** The chats on the computer, the ones moved to history, and the conversations that can be brought over. */
@Composable
fun HubScreen(
    presenter: AgentsHubPresenter,
    folders: FolderPicker,
    onSessionOpened: () -> Unit,
    onChatStarted: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ui by presenter.ui.collectAsState()
    LaunchedEffect(presenter) { presenter.refresh() }
    TitleBarScreen(title = stringResource(R.string.agents_title), modifier = modifier, scrollable = false) {
        if (ui.agents.isNotEmpty()) {
            PrimaryButton(title = stringResource(R.string.agents_new_chat), onClick = presenter::beginNewChat)
        }
        ui.failure?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = PeeringColors.danger) }
        when {
            ui.agents.isEmpty() -> EmptyState(
                icon = null,
                title = stringResource(R.string.agents_empty_title),
                body = stringResource(R.string.agents_unsupported),
                mascot = true,
                modifier = Modifier.padding(top = 32.dp),
            )
            ui.sessions.isEmpty() && ui.history.isEmpty() && ui.resumable.isEmpty() -> EmptyState(
                icon = null,
                title = stringResource(R.string.agents_empty_title),
                body = stringResource(R.string.agents_empty_body),
                mascot = true,
                modifier = Modifier.padding(top = 32.dp),
            )
            else -> HubLists(ui, presenter, onSessionOpened, onChatStarted)
        }
    }
    NewChatSheets(ui, presenter, folders, onChatStarted)
}

@Composable
private fun HubLists(ui: HubUi, presenter: AgentsHubPresenter, onSessionOpened: () -> Unit, onChatStarted: () -> Unit) {
    LazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        chatSection(R.string.agents_chats_title, ui.sessions, presenter, onSessionOpened)
        chatSection(R.string.agents_history_title, ui.history, presenter, onSessionOpened)
        if (ui.resumable.isNotEmpty()) {
            item(key = "resumable-title") { SectionLabel(stringResource(R.string.agents_on_computer_title)) }
            items(ui.resumable, key = { "resumable-" + it.id }) { card ->
                ResumableRow(card, onContinue = { if (presenter.resume(card.id)) onChatStarted() })
            }
        }
    }
}

private fun LazyListScope.chatSection(
    titleRes: Int,
    cards: List<SessionCard>,
    presenter: AgentsHubPresenter,
    onSessionOpened: () -> Unit,
) {
    if (cards.isEmpty()) return
    item(key = "title-$titleRes") { SectionLabel(stringResource(titleRes)) }
    items(cards, key = { it.id }) { card ->
        SessionCardRow(
            card = card,
            onOpen = {
                presenter.openSession(card.id)
                onSessionOpened()
            },
            onPause = { presenter.endSession(card.id) },
            onClose = { presenter.closeSession(card.id) },
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, color = PeeringColors.muted, modifier = Modifier.padding(top = 8.dp))
}

@Composable
private fun NewChatSheets(ui: HubUi, presenter: AgentsHubPresenter, folders: FolderPicker, onChatStarted: () -> Unit) {
    when (ui.newChat) {
        NewChatStep.Closed -> Unit
        NewChatStep.ChoosingAgent -> AgentChoiceSheet(
            agents = ui.agents,
            onChoose = presenter::chooseAgent,
            onDismiss = presenter::cancelNewChat,
        )
        is NewChatStep.ChoosingFolder -> FolderSheet(
            folders = folders,
            recentFolders = ui.recentFolders,
            onUseFolder = { if (presenter.startInChosenFolder()) onChatStarted() },
            onBack = presenter::backToAgents,
            onDismiss = presenter::cancelNewChat,
        )
    }
}
