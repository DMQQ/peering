package pl.dmq.peering.feature.agents

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
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
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.DepthTransition
import pl.dmq.peering.ui.kit.PeeringAlert

/** The Agents page: the chats on the computer, the conversations it holds, and the dock that starts a new chat. */
@Composable
fun HubScreen(
    presenter: AgentsHubPresenter,
    folders: FolderPicker,
    guide: HubGuidePresenter,
    onSessionOpened: () -> Unit,
    onChatStarted: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ui by presenter.ui.collectAsState()
    LaunchedEffect(presenter) { presenter.refresh() }
    val choosingFolder = ui.newChat is NewChatStep.ChoosingFolder
    BackHandler(enabled = choosingFolder, onBack = presenter::cancelNewChat)
    DepthTransition(state = choosingFolder, depth = { if (it) 1 else 0 }, modifier = modifier, label = "hubFolder") { folderPage ->
        if (folderPage) {
            FolderPage(
                folders = folders,
                recentFolders = ui.recentFolders,
                onUseFolder = { if (presenter.startInChosenFolder()) onChatStarted() },
                onUseRecent = { if (presenter.startInRecentFolder(it)) onChatStarted() },
                onBack = presenter::cancelNewChat,
            )
        } else {
            HubBody(ui, presenter, guide, onSessionOpened, onChatStarted)
        }
    }
}

@Composable
private fun HubBody(
    ui: HubUi,
    presenter: AgentsHubPresenter,
    guide: HubGuidePresenter,
    onSessionOpened: () -> Unit,
    onChatStarted: () -> Unit,
) {
    var closing by remember { mutableStateOf<SessionCard?>(null) }
    var renaming by remember { mutableStateOf<SessionCard?>(null) }
    Box(Modifier.fillMaxSize()) {
        HubList(
            ui = ui,
            presenter = presenter,
            guide = guide,
            onClose = { closing = it },
            onRename = { renaming = it },
            onSessionOpened = onSessionOpened,
            onChatStarted = onChatStarted,
        )
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
    renaming?.let { card -> RenamePrompt(card, presenter, onDone = { renaming = null }) }
    closing?.let { card -> ClosePrompt(card, presenter, onDone = { closing = null }) }
}

@Composable
private fun RenamePrompt(card: SessionCard, presenter: AgentsHubPresenter, onDone: () -> Unit) {
    RenameDialog(
        initial = card.title,
        onSave = {
            presenter.renameSession(card.id, it)
            onDone()
        },
        onDismiss = onDone,
    )
}

@Composable
private fun ClosePrompt(card: SessionCard, presenter: AgentsHubPresenter, onDone: () -> Unit) {
    PeeringAlert(
        title = stringResource(R.string.agents_close_title, card.title),
        message = stringResource(R.string.agents_close_message),
        confirm = stringResource(R.string.agents_end_chat),
        onConfirm = {
            presenter.closeSession(card.id)
            onDone()
        },
        cancel = stringResource(R.string.agents_cancel),
        onCancel = onDone,
        destructive = true,
    )
}
