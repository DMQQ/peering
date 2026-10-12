package pl.dmq.peering.feature.remote

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import pl.dmq.peering.R
import pl.dmq.peering.feature.terminal.TerminalGlyphs
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.ChoiceRow
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
        ChoiceRow(
            icon = if (mode == InputMode.TRACKPAD) AppIcons.trackpad else AppIcons.tap,
            title = stringResource(R.string.remote_pointer_title),
            description = stringResource(
                if (mode == InputMode.TRACKPAD) R.string.remote_pointer_trackpad_description else R.string.remote_pointer_touch_description,
            ),
            onClick = onToggleMode,
        )
        ChoiceRow(
            icon = AppIcons.fit,
            title = stringResource(R.string.remote_immersive_title),
            description = stringResource(R.string.remote_immersive_description),
            onClick = onToggleImmersive,
            role = Role.Switch,
            trailing = { PeeringSwitch(checked = immersive, onCheckedChange = { onToggleImmersive() }) },
        )
        entries.forEach { entry ->
            ChoiceRow(
                icon = entry.icon(),
                title = stringResource(entry.labelRes()),
                description = entry.descriptionRes()?.let { stringResource(it) },
                onClick = { onSelect(entry) },
                tint = if (entry == HubEntry.DISCONNECT) PeeringColors.danger else PeeringColors.ink,
            )
        }
    }
}

private fun HubEntry.descriptionRes(): Int? = when (this) {
    HubEntry.QUALITY -> R.string.hub_quality_description
    HubEntry.DISCONNECT -> R.string.hub_disconnect_description
    HubEntry.SOURCES, HubEntry.AGENTS, HubEntry.FILES, HubEntry.TERMINAL -> null
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
