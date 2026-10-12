package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.pendingApprovals
import pl.dmq.peering.ui.kit.PeeringAlert
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/**
 * One chat: the top bar, the conversation (or its loading and empty states), and the options chips over the composer.
 * The approval sheet opens by itself when the agent asks, and again from a tool card's Review.
 */
@Composable
fun ChatScreen(
    chat: ChatPresenter,
    transcript: TranscriptPresenter,
    composer: ComposerPresenter,
    port: AgentsPort,
    onBackToList: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ui by chat.ui.collectAsState()
    val transcriptUi by transcript.ui.collectAsState()
    var showingUsage by remember { mutableStateOf(false) }
    var confirmingClose by remember { mutableStateOf(false) }
    val pending = remember(transcriptUi.rows) { pendingApprovals(transcriptUi.rows) }
    var reviewingID by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(pending.firstOrNull()?.approvalID) { reviewingID = pending.firstOrNull()?.approvalID }

    Column(modifier = modifier.fillMaxSize()) {
        ChatTopBar(
            ui = ui,
            onBack = onBackToList,
            onShowUsage = { showingUsage = true },
            onPause = { if (chat.pause()) onBackToList() },
            onClose = { confirmingClose = true },
        )
        Box(Modifier.weight(1f)) {
            when {
                transcriptUi.loadingHistory && transcriptUi.rows.isEmpty() -> HistoryLoading()
                ui.showEmptyState -> EmptyChat(ui = ui, onSuggest = chat::suggest)
                else -> TranscriptList(
                    presenter = transcript,
                    onAskAgain = {
                        transcript.followLatest()
                        chat.suggest(it)
                    },
                    onReview = { reviewingID = it },
                )
            }
        }
        Composer(composer, ui.chip, onShowUsage = { showingUsage = true }, modifier = Modifier.navigationBarsPadding().imePadding())
    }
    if (showingUsage) UsageSheet(usage = ui.usage, agentName = ui.agentName, onDismiss = { showingUsage = false })
    pending.firstOrNull { it.approvalID == reviewingID }?.let { approval ->
        ui.sessionID?.let { sessionID ->
            ApprovalSheet(port, sessionID, approval, onDismiss = { reviewingID = null })
        }
    }
    if (confirmingClose) {
        PeeringAlert(
            title = stringResource(R.string.agents_close_title, ui.title),
            message = stringResource(R.string.agents_close_message),
            confirm = stringResource(R.string.agents_end_chat),
            onConfirm = {
                confirmingClose = false
                chat.close()
                onBackToList()
            },
            cancel = stringResource(R.string.agents_cancel),
            onCancel = { confirmingClose = false },
            destructive = true,
        )
    }
}


@Composable
private fun HistoryLoading() {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally) {
        CircularProgressIndicator(color = PeeringColors.ink.copy(alpha = 0.7f), strokeWidth = 2.dp)
        Text(stringResource(R.string.agents_history_loading), style = PeeringText.footnote, color = PeeringColors.ink.copy(alpha = 0.5f))
    }
}
