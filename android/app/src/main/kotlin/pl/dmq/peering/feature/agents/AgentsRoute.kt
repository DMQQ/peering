package pl.dmq.peering.feature.agents

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import pl.dmq.peering.feature.agents.attach.AttachmentSender
import pl.dmq.peering.feature.agents.changes.ChangesOverlay
import pl.dmq.peering.feature.agents.review.ReviewInbox
import pl.dmq.peering.feature.agents.review.ReviewScreen
import pl.dmq.peering.feature.remote.HubTab
import pl.dmq.peering.feature.remote.ReportHubPage
import pl.dmq.peering.session.agent.DirectoryLister
import pl.dmq.peering.session.agent.changes.ReviewMarkStore
import pl.dmq.peering.session.agent.PromptTemplateStore
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.ui.kit.rememberWidthClass
import pl.dmq.peering.session.ports.KeyValueStore

/**
 * The agents feature as one screen: the hub of chats, and the chat open on it. Everything the screens need arrives
 * through [port].
 */
@Composable
fun AgentsRoute(
    port: AgentsPort,
    recents: FolderRecents,
    declaredAgentIDs: List<String>,
    chatSupported: Boolean,
    modelPickerSupported: Boolean,
    draftStore: ComposerDraftStore,
    guideStore: KeyValueStore,
    clock: Clock,
    attachments: AttachmentSender?,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val folders = remember(port) { FolderPicker(port::browse, scope) }
    val hub = remember(port, declaredAgentIDs, chatSupported) {
        AgentsHubPresenter(port, declaredAgentIDs, chatSupported, folders, recents, clock, scope)
    }
    val guide = remember(guideStore) { HubGuidePresenter(guideStore) }
    val chat = remember(port) { ChatPresenter(port, scope) }
    val templates = remember(guideStore) { PromptTemplatesPresenter(PromptTemplateStore(guideStore)) }
    val transcript = remember(port) { TranscriptPresenter(port.chats, scope) }
    val composer = remember(port, modelPickerSupported, attachments) {
        ComposerPresenter(port, draftStore, port.chats, modelPickerSupported, scope, attachments)
    }
    val lister = remember(port) { DirectoryLister(port::browse, scope, System::currentTimeMillis) }
    val hints = remember(composer, lister) { ComposerHints(composer.ui, lister, composer.hintOffers, scope) }
    val review = remember(port, guideStore) { ReviewInbox(port, ReviewMarkStore(guideStore), scope, System::currentTimeMillis) }
    var reviewing by remember { mutableStateOf(false) }
    var reviewedFile by remember { mutableStateOf<Pair<String, String>?>(null) }
    val chatState by port.chats.collectAsState()
    val hubUi by hub.ui.collectAsState()
    var showingChat by remember { mutableStateOf(false) }
    var sessionsBeforeStart by remember { mutableStateOf<Set<String>?>(null) }
    LaunchedEffect(chatState.sessions, sessionsBeforeStart) {
        val before = sessionsBeforeStart ?: return@LaunchedEffect
        if (chatState.sessions.any { it.id !in before }) {
            sessionsBeforeStart = null
            showingChat = true
        }
    }

    LaunchedEffect(folders) {
        port.browseEvents.collect {
            folders.onEvent(it)
            lister.onEvent(it)
        }
    }

    val twoPane = rememberWidthClass().twoPane
    Surface(modifier = modifier, color = MaterialTheme.colorScheme.background) {
        val chatOpen = showingChat && chatState.selected != null
        ReportHubPage(HubTab.AGENTS, atRoot = !chatOpen && !reviewing && hubUi.newChat !is NewChatStep.ChoosingFolder)
        BackHandler(enabled = chatOpen && !twoPane) { showingChat = false }
        Box(Modifier.fillMaxSize()) {
            AgentsPanes(
                twoPane = twoPane,
                chatOpen = chatOpen,
                hub = {
                    HubScreen(
                        presenter = hub,
                        guide = guide,
                        review = review,
                        onOpenReview = { reviewing = true },
                        folders = folders,
                        onSessionOpened = { showingChat = true },
                        onChatStarted = { sessionsBeforeStart = chatState.sessions.map { it.id }.toSet() },
                    )
                },
                chat = {
                    ChatScreen(
                        chat = chat,
                        transcript = transcript,
                        composer = composer,
                        hints = hints,
                        templates = templates,
                        port = port,
                        onBackToList = { showingChat = false },
                    )
                },
            )
            if (reviewing) {
                ReviewScreen(review, onOpenFile = { chat, path -> reviewedFile = chat to path }, onClose = { reviewing = false })
            }
            reviewedFile?.let { (chatId, path) ->
                ChangesOverlay(port, chatId, onClose = { reviewedFile = null }, initialPath = path)
            }
        }
    }
}
