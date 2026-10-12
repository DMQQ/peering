package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
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
import pl.dmq.peering.ui.kit.TitleBarScreen
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.theme.PeeringColors

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
        if (ui.agents.isEmpty()) {
            Text(stringResource(R.string.agents_unsupported), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
        } else if (ui.sessions.isEmpty()) {
            Text(stringResource(R.string.agents_empty_body), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            items(ui.sessions, key = { it.id }) { card ->
                SessionCardRow(
                    card = card,
                    onOpen = {
                        presenter.openSession(card.id)
                        onSessionOpened()
                    },
                    onEnd = { presenter.closeSession(card.id) },
                )
            }
        }
    }
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
