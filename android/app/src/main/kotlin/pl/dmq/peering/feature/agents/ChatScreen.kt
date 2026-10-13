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
import pl.dmq.peering.feature.agents.changes.ChangesOverlay
import pl.dmq.peering.feature.agents.preview.previewFetchOf
import pl.dmq.peering.feature.agents.preview.PreviewScreen
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
    hints: ComposerHints?,
    templates: PromptTemplatesPresenter,
    port: AgentsPort,
    onBackToList: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ui by chat.ui.collectAsState()
    val transcriptUi by transcript.ui.collectAsState()
    val saved by templates.templates.collectAsState()
    var showingUsage by remember { mutableStateOf(false) }
    var showingChanges by remember { mutableStateOf(false) }
    var showingPreview by remember { mutableStateOf(false) }
    val previewFetch = remember(port.preview) { port.preview?.let(::previewFetchOf) }
    var renaming by remember { mutableStateOf(false) }
    var typingModel by remember { mutableStateOf(false) }
    var confirmingClose by remember { mutableStateOf(false) }
    val pending = remember(transcriptUi.rows) { pendingApprovals(transcriptUi.rows) }
    var reviewingID by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(pending.firstOrNull()?.approvalID) { reviewingID = pending.firstOrNull()?.approvalID }
    LaunchedEffect(composer) {
        composer.appCommands.collect { name ->
            when (name) {
                "usage" -> showingUsage = true
                "model" -> typingModel = true
                else -> renaming = true
            }
        }
    }

    Box(modifier.fillMaxSize()) {
        Column(modifier = Modifier.fillMaxSize()) {
            ChatTopBar(
                ui = ui,
                onBack = onBackToList,
                onShowUsage = { showingUsage = true },
                onShowChanges = { showingChanges = true },
            onShowPreview = previewFetch?.let { { showingPreview = true } },
            onRename = { renaming = true },
                onPause = { if (chat.pause()) onBackToList() },
                onClose = { confirmingClose = true },
            )
            Box(Modifier.weight(1f)) {
                when {
                    transcriptUi.loadingHistory && transcriptUi.rows.isEmpty() -> HistoryLoading()
                    ui.showEmptyState -> EmptyChat(
                        ui = ui,
                        templates = saved.entries,
                        onSuggest = chat::suggest,
                        onSaveTemplate = templates::add,
                        onRemoveTemplate = templates::remove,
                    )
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
            Composer(composer, ui.chip, hints, onShowUsage = { showingUsage = true }, onCustomModel = { typingModel = true }, modifier = Modifier.navigationBarsPadding().imePadding())
        }
        if (showingChanges) ui.sessionID?.let { ChangesOverlay(port, it, onClose = { showingChanges = false }) }
        if (showingPreview && previewFetch != null) PreviewScreen(previewFetch, onClose = { showingPreview = false })
    }
    if (showingUsage) UsageSheet(usage = ui.usage, agentName = ui.agentName, onDismiss = { showingUsage = false })
    pending.firstOrNull { it.approvalID == reviewingID }?.let { approval ->
        ui.sessionID?.let { sessionID ->
            ApprovalSheet(port, sessionID, approval, onDismiss = { reviewingID = null })
        }
    }
    if (typingModel) {
        val current = composerModel(composer)
        CustomModelDialog(current, onUse = { composer.setModel(it.ifBlank { null }) }, onDismiss = { typingModel = false })
    }
    if (renaming) {
        RenameDialog(
            initial = ui.title,
            onSave = {
                chat.rename(it)
                renaming = false
            },
            onDismiss = { renaming = false },
        )
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

@Composable
private fun composerModel(composer: ComposerPresenter): String {
    val ui by composer.ui.collectAsState()
    return ui.model.orEmpty()
}
