package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
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
import pl.dmq.peering.ui.theme.PeeringColors

@Composable
fun HubScreen(
    presenter: AgentsHubPresenter,
    folders: FolderPicker,
    modifier: Modifier = Modifier,
) {
    val ui by presenter.ui.collectAsState()
    LaunchedEffect(presenter) { presenter.refresh() }
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(stringResource(R.string.agents_title), style = MaterialTheme.typography.headlineLarge)
        if (ui.agents.isNotEmpty()) {
            Button(
                onClick = presenter::beginNewChat,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = PeeringColors.ink, contentColor = PeeringColors.onInk),
            ) {
                Text(stringResource(R.string.agents_new_chat), style = MaterialTheme.typography.labelLarge)
            }
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
                    onOpen = { presenter.openSession(card.id) },
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
            onUseFolder = presenter::startInChosenFolder,
            onBack = presenter::backToAgents,
            onDismiss = presenter::cancelNewChat,
        )
    }
}
