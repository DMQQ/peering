package pl.dmq.peering.feature.ssh

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.SwapHoriz
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
import pl.dmq.peering.ssh.model.SshPortForward
import pl.dmq.peering.ssh.session.ForwardStatus
import pl.dmq.peering.ssh.session.LiveServer
import pl.dmq.peering.ssh.session.SshServers
import pl.dmq.peering.ui.kit.ControlLink
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.PeeringListItem
import pl.dmq.peering.ui.kit.PeeringSwitch
import pl.dmq.peering.ui.theme.IconTile
import java.util.UUID

/** The tunnels of one open server: saved with the server, started with its connection, and switchable while it runs. */
@Composable
internal fun ForwardsScreen(server: LiveServer, servers: SshServers) {
    val hosts by servers.hosts.collectAsState()
    val status by server.session.forwardStatus.collectAsState()
    val forwards = hosts.firstOrNull { it.id == server.id }?.forwards ?: server.host.forwards
    var editing by remember { mutableStateOf<SshPortForward?>(null) }
    var adding by remember { mutableStateOf(false) }

    fun saveForwards(list: List<SshPortForward>) {
        val host = hosts.firstOrNull { it.id == server.id } ?: return
        servers.save(host.copy(forwards = list))
    }

    fun toggle(forward: SshPortForward, on: Boolean) {
        saveForwards(forwards.map { if (it.id == forward.id) it.copy(isEnabled = on) else it })
        if (on) server.session.startForward(forward) else server.session.stopForward(forward.id)
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(18.dp)) {
        ControlsCard(
            stringResource(R.string.ssh_forwards_title),
            footer = stringResource(if (forwards.isEmpty()) R.string.ssh_forwards_footer_idle else R.string.ssh_forwards_footer_live),
        ) {
            forwards.forEach { forward ->
                PeeringListItem(
                    headline = forward.displayName,
                    supporting = listOf(forward.detail, statusText(status[forward.id])).joinToString(" · "),
                    onClick = { editing = forward },
                    leading = { IconTile(Icons.Outlined.SwapHoriz, size = 40.dp) },
                    trailing = { PeeringSwitch(status[forward.id] == ForwardStatus.Running, { toggle(forward, it) }) },
                )
            }
            ControlLink(stringResource(R.string.ssh_forward_add), Icons.Outlined.Add, { adding = true })
        }
    }
    if (adding || editing != null) {
        ForwardEditorSheet(
            existing = forwards,
            editing = editing,
            newId = { UUID.randomUUID().toString() },
            onSave = { forward ->
                val known = forwards.any { it.id == forward.id }
                saveForwards(if (known) forwards.map { if (it.id == forward.id) forward else it } else forwards + forward)
                server.session.stopForward(forward.id)
                if (forward.isEnabled) server.session.startForward(forward)
                adding = false
                editing = null
            },
            onDelete = { forward ->
                server.session.stopForward(forward.id)
                saveForwards(forwards.filterNot { it.id == forward.id })
                editing = null
            },
            onDismiss = {
                adding = false
                editing = null
            },
        )
    }
}

@Composable
private fun statusText(status: ForwardStatus?): String = when (status) {
    ForwardStatus.Running -> stringResource(R.string.ssh_forward_running)
    is ForwardStatus.Failed -> status.reason
    ForwardStatus.Stopped, null -> stringResource(R.string.ssh_forward_stopped)
}
