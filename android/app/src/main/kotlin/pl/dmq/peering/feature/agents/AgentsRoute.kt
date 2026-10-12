package pl.dmq.peering.feature.agents

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
import kotlinx.coroutines.flow.Flow
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.wire.AgentEvent

/**
 * The agents feature as one screen: the hub of chats, and the chat open on it. [browseEvents] carries the Mac's
 * folder listings and failures; everything else the screens need arrives through [port].
 */
@Composable
fun AgentsRoute(
    port: AgentsPort,
    browseEvents: Flow<AgentEvent>,
    declaredAgentIDs: List<String>,
    chatSupported: Boolean,
    modelPickerSupported: Boolean,
    draftStore: ComposerDraftStore,
    clock: Clock,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val folders = remember(port) { FolderPicker(port::browse, scope) }
    val hub = remember(port, declaredAgentIDs, chatSupported) {
        AgentsHubPresenter(port, declaredAgentIDs, chatSupported, folders, clock, scope)
    }
    val transcript = remember(port) { TranscriptPresenter(port.chats, scope) }
    val composer = remember(port, modelPickerSupported) {
        ComposerPresenter(port, draftStore, port.chats, modelPickerSupported, scope)
    }
    val chatState by port.chats.collectAsState()
    var showingChat by remember { mutableStateOf(false) }

    LaunchedEffect(folders) {
        browseEvents.collect(folders::onEvent)
    }

    Surface(modifier = modifier, color = MaterialTheme.colorScheme.background) {
        val selected = chatState.selected
        if (showingChat && selected != null) {
            ChatScreen(
                transcript = transcript,
                composer = composer,
                port = port,
                title = selected.info.title,
                directory = selected.info.directory,
                onBackToList = { showingChat = false },
            )
        } else {
            HubScreen(
                presenter = hub,
                folders = folders,
                onSessionOpened = { showingChat = true },
            )
        }
    }
}
