package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.theme.PeeringColors

/** The menu of a trusted computer: pick the route, rename it on this device, or forget it. */
@Composable
internal fun HostMenu(row: HostRow, actions: ConnectActions, onRename: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    fun choose(action: () -> Unit) {
        open = false
        action()
    }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(AppIcons.more, stringResource(R.string.connect_more), tint = PeeringColors.muted)
        }
        PeeringMenu(open, { open = false }) {
            PeeringMenuItem(
                title = stringResource(R.string.connect_via_lan),
                onClick = { choose { actions.onConnectVia(row.id, ConnectVia.Lan) } },
                icon = AppIcons.wifi,
                enabled = row.route == HostRoute.Local,
            )
            PeeringMenuItem(
                title = stringResource(R.string.connect_via_relay),
                onClick = { choose { actions.onConnectVia(row.id, ConnectVia.Relay) } },
                icon = AppIcons.network,
            )
            PeeringMenuItem(title = stringResource(R.string.connect_rename), onClick = { choose(onRename) }, icon = AppIcons.edit)
            PeeringMenuItem(
                title = stringResource(R.string.connect_forget),
                onClick = { choose { actions.onForget(row.id) } },
                icon = AppIcons.delete,
                destructive = true,
            )
        }
    }
}
