package pl.dmq.peering.feature.ssh

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ssh.model.SshHost
import pl.dmq.peering.ssh.session.LiveServer
import pl.dmq.peering.ssh.session.SshPhase
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.ControlLink
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.PeeringListItem
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.kit.TabScreen
import pl.dmq.peering.ui.theme.EmptyState
import pl.dmq.peering.ui.theme.IconTile
import pl.dmq.peering.ui.theme.PeeringColors

/** What a row of the list can ask for. */
internal class ServerRowActions(
    val open: (SshHost) -> Unit,
    val edit: (SshHost) -> Unit,
    val showPublicKey: (SshHost) -> Unit,
    val forgetSignIn: (SshHost) -> Unit,
    val forgetKey: (SshHost) -> Unit,
    val delete: (SshHost) -> Unit,
)

/** What the list knows about a server that its row needs to decide on menu items. */
internal class ServerFacts(val hasSignIn: Boolean, val hasKey: Boolean, val hasPrivateKey: Boolean)

@Composable
internal fun ServersScreen(
    hosts: List<SshHost>,
    live: List<LiveServer>,
    facts: (SshHost) -> ServerFacts,
    actions: ServerRowActions,
    onAdd: () -> Unit,
    onOpenLive: (LiveServer) -> Unit,
    onEnd: (LiveServer) -> Unit,
) {
    TabScreen(stringResource(R.string.ssh_title), stringResource(R.string.ssh_detail)) {
        if (live.isNotEmpty()) {
            ControlsCard(stringResource(R.string.ssh_section_open)) {
                live.forEach { server -> LiveRow(server, onOpenLive, onEnd) }
            }
        }
        if (hosts.isEmpty()) {
            EmptyState(Icons.Outlined.Dns, stringResource(R.string.ssh_empty_title), stringResource(R.string.ssh_empty_body))
        }
        ControlsCard(stringResource(R.string.ssh_section_servers)) {
            hosts.forEach { host -> HostRow(host, facts(host), actions) }
            ControlLink(stringResource(R.string.ssh_add), Icons.Outlined.Add, onAdd)
        }
    }
}

@Composable
private fun LiveRow(server: LiveServer, onOpen: (LiveServer) -> Unit, onEnd: (LiveServer) -> Unit) {
    val phase by server.session.phase.collectAsState()
    val template = when (phase) {
        SshPhase.Connecting -> R.string.ssh_row_connecting
        SshPhase.Live -> R.string.ssh_row_live
        is SshPhase.Ended -> R.string.ssh_row_ended
    }
    PeeringListItem(
        headline = server.host.displayName,
        supporting = stringResource(template, server.host.detail),
        onClick = { onOpen(server) },
        leading = { IconTile(Icons.Outlined.Terminal, size = 40.dp, tint = if (phase == SshPhase.Live) PeeringColors.added else PeeringColors.ink) },
        trailing = {
            IconButton(onClick = { onEnd(server) }) {
                Icon(AppIcons.close, stringResource(R.string.ssh_menu_end), Modifier.size(20.dp))
            }
        },
    )
}

@Composable
private fun HostRow(host: SshHost, facts: ServerFacts, actions: ServerRowActions) {
    PeeringListItem(
        headline = host.displayName,
        supporting = if (host.lock.isLocked) stringResource(R.string.ssh_row_locked, host.detail) else host.detail,
        onClick = { actions.open(host) },
        leading = { IconTile(Icons.Outlined.Dns, size = 40.dp) },
        trailing = { RowMenu(host, facts, actions) },
    )
}

@Composable
private fun RowMenu(host: SshHost, facts: ServerFacts, actions: ServerRowActions) {
    var open by remember { mutableStateOf(false) }
    fun run(action: (SshHost) -> Unit): () -> Unit = {
        open = false
        action(host)
    }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(AppIcons.more, stringResource(R.string.ssh_row_more, host.displayName), Modifier.size(20.dp))
        }
        PeeringMenu(open, onDismiss = { open = false }) {
            PeeringMenuItem(stringResource(R.string.ssh_menu_edit), run(actions.edit), icon = AppIcons.edit)
            if (facts.hasPrivateKey) PeeringMenuItem(stringResource(R.string.ssh_menu_public_key), run(actions.showPublicKey), icon = AppIcons.copy)
            if (facts.hasSignIn) PeeringMenuItem(stringResource(R.string.ssh_menu_forget_signin), run(actions.forgetSignIn), destructive = true)
            if (facts.hasKey) PeeringMenuItem(stringResource(R.string.ssh_menu_forget_key), run(actions.forgetKey), destructive = true)
            PeeringMenuItem(stringResource(R.string.ssh_menu_delete), run(actions.delete), icon = AppIcons.delete, destructive = true)
        }
    }
}
