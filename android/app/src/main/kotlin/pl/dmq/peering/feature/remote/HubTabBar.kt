package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.theme.PeeringColors

/** The top of the hub panel: the tabs the computer offers as one segmented switcher, and the button that closes the panel. */
@Composable
fun HubTabBar(
    offered: List<HubTab>,
    selected: HubTab?,
    onSelect: (HubTab) -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        SingleChoiceSegmentedButtonRow(Modifier.weight(1f)) {
            offered.forEachIndexed { index, tab ->
                SegmentedButton(
                    selected = tab == selected,
                    onClick = { onSelect(tab) },
                    shape = SegmentedButtonDefaults.itemShape(index, offered.size),
                    colors = SegmentedButtonDefaults.colors(
                        activeContainerColor = PeeringColors.ink,
                        activeContentColor = PeeringColors.onInk,
                        inactiveContainerColor = PeeringColors.containerHigh,
                        inactiveContentColor = PeeringColors.muted,
                        activeBorderColor = Color.Transparent,
                        inactiveBorderColor = Color.Transparent,
                    ),
                    icon = { Icon(tab.icon(), contentDescription = null, modifier = Modifier.size(SegmentedButtonDefaults.IconSize)) },
                    label = { Text(stringResource(tab.titleRes()), maxLines = 1) },
                )
            }
        }
        IconButton(onClick = onClose) {
            Icon(AppIcons.close, contentDescription = stringResource(R.string.hub_close), tint = PeeringColors.ink)
        }
    }
}

private fun HubTab.titleRes(): Int = when (this) {
    HubTab.AGENTS -> R.string.hub_agents
    HubTab.TERMINALS -> R.string.hub_terminals
    HubTab.FILES -> R.string.hub_files
}

private fun HubTab.icon() = when (this) {
    HubTab.AGENTS -> AppIcons.sparkles
    HubTab.TERMINALS -> SessionIcons.terminal
    HubTab.FILES -> AppIcons.folder
}
