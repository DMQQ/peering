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
import pl.dmq.peering.session.ports.Clock

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
    clock: Clock,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val folders = remember(port) { FolderPicker(port::browse, scope) }
    val hub = remember(port, declaredAgentIDs, chatSupported) {
        AgentsHubPresenter(port, declaredAgentIDs, chatSupported, folders, recents, clock, scope)
    }
    val transcript = remember(port) { TranscriptPresenter(port.chats, scope) }
    val composer = remember(port, modelPickerSupported) {
        ComposerPresenter(port, draftStore, port.chats, modelPickerSupported, scope)
    }
    val chatState by port.chats.collectAsState()
    var showingChat by remember { mutableStateOf(false) }

    LaunchedEffect(folders) {
        port.browseEvents.collect(folders::onEvent)
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
