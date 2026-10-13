package pl.dmq.peering.feature.ssh

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.files.FilesRoute
import pl.dmq.peering.feature.terminal.TerminalRoute
import pl.dmq.peering.ssh.model.SshAuthMethod
import pl.dmq.peering.ssh.session.LiveServer
import pl.dmq.peering.ssh.session.SshPhase
import pl.dmq.peering.ssh.model.SshCredential
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.nav.HideNavigationBar
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

private enum class SessionTab(val label: Int) {
    TERMINAL(R.string.ssh_tab_terminal),
    FILES(R.string.ssh_tab_files),
    FORWARDS(R.string.ssh_tab_forwards),
}

/** One open server: a header, then its shells, its files or its tunnels. The connection lives on when the user steps back to the list. */
@Composable
internal fun SshSessionScreen(
    server: LiveServer,
    hub: SshHub,
    method: SshAuthMethod,
    onBack: () -> Unit,
    onEnd: () -> Unit,
    onReconnect: () -> Unit,
) {
    val phase by server.session.phase.collectAsState()
    val shells by server.terminals.state.collectAsState()
    var tab by rememberSaveable { mutableStateOf(SessionTab.TERMINAL) }
    var confirmingEnd by remember { mutableStateOf(false) }
    HideNavigationBar()
    BackHandler(onBack = onBack)

    Column(Modifier.fillMaxSize()) {
        Header(server, phase, tab, { tab = it }, onBack, onEnd = { if (phase is SshPhase.Live) confirmingEnd = true else onEnd() })
        Box(Modifier.weight(1f).fillMaxWidth()) {
            val ended = phase as? SshPhase.Ended
            when {
                phase == SshPhase.Connecting -> Connecting(server.host.displayName, onCancel = onEnd)
                ended != null && !shells.loaded -> EndedCard(ended, method, onReconnect, onEnd)
                else -> Column(Modifier.fillMaxSize()) {
                    if (ended != null) EndedBanner(ended, method, onReconnect)
                    Box(Modifier.weight(1f)) { SessionBody(tab, server, hub, phase is SshPhase.Live, onBack = { tab = SessionTab.TERMINAL }, onLeave = onBack) }
                }
            }
        }
    }
    if (confirmingEnd) EndConnectionDialog(onEnd = { confirmingEnd = false; onEnd() }, onKeep = { confirmingEnd = false })
}

@Composable
private fun Header(server: LiveServer, phase: SshPhase, tab: SessionTab, onTab: (SessionTab) -> Unit, onBack: () -> Unit, onEnd: () -> Unit) {
    Column(Modifier.fillMaxWidth().statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(AppIcons.back, stringResource(R.string.ssh_back), Modifier.size(22.dp)) }
            Column(Modifier.weight(1f)) {
                Text(server.host.displayName, style = PeeringText.subheadlineSemibold, color = PeeringColors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(statusLine(server, phase), style = PeeringText.caption, color = PeeringColors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            IconButton(onClick = onEnd) { Icon(AppIcons.close, stringResource(R.string.ssh_menu_end), Modifier.size(22.dp)) }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SessionTab.entries.forEach { SegmentChip(stringResource(it.label), selected = it == tab) { onTab(it) } }
        }
    }
}

@Composable
private fun statusLine(server: LiveServer, phase: SshPhase): String = stringResource(
    when (phase) {
        SshPhase.Connecting -> R.string.ssh_row_connecting
        SshPhase.Live -> R.string.ssh_row_live
        is SshPhase.Ended -> R.string.ssh_row_ended
    },
    server.host.detail,
)

@Composable
private fun SessionBody(tab: SessionTab, server: LiveServer, hub: SshHub, live: Boolean, onBack: () -> Unit, onLeave: () -> Unit) {
    val resolver = LocalContext.current.contentResolver
    when (tab) {
        SessionTab.TERMINAL -> TerminalRoute(server.terminals, hub.terminalPreferences, connected = live, onBack = onLeave, hosted = true)
        SessionTab.FILES -> if (live) {
            FilesRoute(hub.files(server, resolver), onBack = onBack, hosted = true)
        } else {
            Text(stringResource(R.string.ssh_files_ended), style = PeeringText.subheadline, color = PeeringColors.muted, modifier = Modifier.padding(24.dp))
        }
        SessionTab.FORWARDS -> ForwardsScreen(server, hub.servers)
    }
}

/** The credential kind a server signs in with, which decides what a refused sign-in says. */
internal fun SshCredential?.methodOrPassword(): SshAuthMethod = this?.method ?: SshAuthMethod.PASSWORD
