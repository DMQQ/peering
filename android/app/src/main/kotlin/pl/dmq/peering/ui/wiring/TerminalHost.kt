package pl.dmq.peering.ui.wiring

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.FolderRecents
import pl.dmq.peering.feature.agents.FolderRecentsStore
import pl.dmq.peering.feature.agents.HubGuidePresenter
import pl.dmq.peering.feature.files.FolderPickerPresenter
import pl.dmq.peering.feature.terminal.AgentLaunchHistory
import pl.dmq.peering.feature.terminal.QuickCommands
import pl.dmq.peering.feature.terminal.TerminalPreferences
import pl.dmq.peering.feature.terminal.TerminalPage
import pl.dmq.peering.feature.terminal.TerminalTextSizeSetting
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.ports.KeyValueStore
import pl.dmq.peering.ui.theme.PeeringColors

private const val TERMINAL_RECENTS_SUFFIX = "#terminal"

/** The Terminals page over the active session's shells, or a line saying there are none to offer. */
@Composable
internal fun TerminalHost(active: ActiveSession, guideStore: KeyValueStore, folderRecents: FolderRecentsStore, onFiles: (() -> Unit)?) {
    val sessions = active.controller.terminals
    if (sessions == null) {
        Box(modifier = Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
            Text(
                text = stringResource(R.string.session_unavailable_terminal),
                style = MaterialTheme.typography.bodyMedium,
                color = PeeringColors.muted,
            )
        }
        return
    }
    val phase by active.controller.state.collectAsState()
    val context = LocalContext.current
    val preferences = remember(context) {
        val store = PreferencesKeyValueStore(context.getSharedPreferences("peering_terminal", Context.MODE_PRIVATE), context.preferenceWrites())
        TerminalPreferences(QuickCommands(store), TerminalTextSizeSetting(store), AgentLaunchHistory(store))
    }
    val guide = remember(guideStore) { HubGuidePresenter(guideStore, HubGuidePresenter.TERMINALS_KEY) }
    val ready = phase.phase as? SessionPhase.Ready
    val browser = active.controller.files
    val scope = rememberCoroutineScope()
    val folders = browser?.let { rememberFileBrowsing(active, it) }
        ?.let { port -> remember(port) { FolderPickerPresenter(port, scope) } }
    val recents = remember(folderRecents, active.target.hostId) {
        FolderRecents(folderRecents, active.target.hostId.orEmpty() + TERMINAL_RECENTS_SUFFIX)
    }
    TerminalPage(
        sessions, preferences, guide,
        connected = ready != null,
        computerName = ready?.hostName.orEmpty(),
        onFiles = onFiles,
        folders = folders,
        recents = recents,
    )
}
