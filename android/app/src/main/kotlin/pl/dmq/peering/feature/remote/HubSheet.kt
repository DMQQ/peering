package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.terminal.TerminalGlyphs
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringListItem
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.PeeringSwitch
import pl.dmq.peering.ui.theme.PeeringColors


/** The More sheet: the pointer mode, then one list item per entry. Disconnect is last, after a divider, in the error colour. */
@Composable
fun HubSheet(
    entries: List<HubEntry>,
    mode: InputMode,
    immersive: Boolean,
    onToggleMode: () -> Unit,
    onToggleImmersive: () -> Unit,
    onSelect: (HubEntry) -> Unit,
    onDismiss: () -> Unit,
) {
    PeeringSheet(onDismiss = onDismiss, title = stringResource(R.string.hub_title)) {
        PeeringListItem(
            headline = stringResource(R.string.remote_pointer_title),
            supporting = stringResource(
                if (mode == InputMode.TRACKPAD) R.string.remote_pointer_trackpad else R.string.remote_pointer_touch,
            ),
            onClick = onToggleMode,
            role = Role.Button,
            bleed = false,
            leading = { Icon(if (mode == InputMode.TRACKPAD) AppIcons.trackpad else AppIcons.tap, contentDescription = null) },
        )
        PeeringListItem(
            headline = stringResource(R.string.remote_immersive_title),
            supporting = stringResource(R.string.remote_immersive_description),
            onClick = onToggleImmersive,
            role = Role.Switch,
            bleed = false,
            leading = { Icon(AppIcons.fit, contentDescription = null) },
            trailing = { PeeringSwitch(checked = immersive, onCheckedChange = { onToggleImmersive() }) },
        )
        entries.forEach { entry ->
            if (entry == HubEntry.DISCONNECT) HorizontalDivider(Modifier.padding(vertical = 8.dp), color = PeeringColors.hairline)
            val tint = if (entry == HubEntry.DISCONNECT) PeeringColors.danger else PeeringColors.ink
            PeeringListItem(
                headline = stringResource(entry.labelRes()),
                onClick = { onSelect(entry) },
                role = Role.Button,
                tint = tint,
                bleed = false,
                leading = { Icon(entry.icon(), contentDescription = null) },
            )
        }
    }
}

private fun HubEntry.icon(): ImageVector = when (this) {
    HubEntry.SOURCES -> AppIcons.display
    HubEntry.AGENTS -> AppIcons.sparkles
    HubEntry.FILES -> AppIcons.folder
    HubEntry.TERMINAL -> TerminalGlyphs.terminal
    HubEntry.QUALITY -> AppIcons.tune
    HubEntry.DISCONNECT -> AppIcons.power
}

private fun HubEntry.labelRes(): Int = when (this) {
    HubEntry.SOURCES -> R.string.hub_sources
    HubEntry.AGENTS -> R.string.hub_agents
    HubEntry.FILES -> R.string.hub_files
    HubEntry.TERMINAL -> R.string.hub_terminal
    HubEntry.QUALITY -> R.string.hub_quality
    HubEntry.DISCONNECT -> R.string.hub_disconnect
}
