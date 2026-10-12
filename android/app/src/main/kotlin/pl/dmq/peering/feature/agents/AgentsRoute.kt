package pl.dmq.peering.feature.agents

import androidx.activity.compose.BackHandler
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
import pl.dmq.peering.feature.remote.HubTab
import pl.dmq.peering.feature.remote.ReportHubPage
import pl.dmq.peering.session.agent.PromptTemplateStore
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.ui.kit.DepthTransition
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
    val composer = remember(port, modelPickerSupported) {
        ComposerPresenter(port, draftStore, port.chats, modelPickerSupported, scope)
    }
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
        port.browseEvents.collect(folders::onEvent)
    }

    Surface(modifier = modifier, color = MaterialTheme.colorScheme.background) {
        val chatOpen = showingChat && chatState.selected != null
        ReportHubPage(HubTab.AGENTS, atRoot = !chatOpen && hubUi.newChat !is NewChatStep.ChoosingFolder)
        BackHandler(enabled = chatOpen) { showingChat = false }
        DepthTransition(state = chatOpen, depth = { if (it) 1 else 0 }, label = "agentsChat") { openChat ->
            if (openChat) {
                ChatScreen(
                    chat = chat,
                    transcript = transcript,
                    composer = composer,
                    templates = templates,
                    port = port,
                    onBackToList = { showingChat = false },
                )
            } else {
                HubScreen(
                    presenter = hub,
                    guide = guide,
                    folders = folders,
                    onSessionOpened = { showingChat = true },
                    onChatStarted = { sessionsBeforeStart = chatState.sessions.map { it.id }.toSet() },
                )
            }
        }
    }
}
