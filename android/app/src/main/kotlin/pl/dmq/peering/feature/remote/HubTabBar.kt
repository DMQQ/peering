package pl.dmq.peering.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape

/** The height of [HubTabBar] without the status bar. */
val HubTabBarHeight = 52.dp

/** The top of the hub panel: the tabs the computer offers as one pill track, and the button that closes the panel. */
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
        Row(
            Modifier.weight(1f).height(44.dp).clip(PillShape).background(PeeringColors.containerHigh).padding(4.dp).selectableGroup(),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            offered.forEach { tab -> HubTabSegment(tab, tab == selected, { onSelect(tab) }, Modifier.weight(1f)) }
        }
        IconButton(onClick = onClose, modifier = Modifier.size(48.dp)) {
            Icon(AppIcons.close, contentDescription = stringResource(R.string.hub_close), tint = PeeringColors.ink)
        }
    }
}

@Composable
private fun HubTabSegment(tab: HubTab, selected: Boolean, onClick: () -> Unit, modifier: Modifier) {
    val tint = if (selected) PeeringColors.onInk else PeeringColors.muted
    Row(
        modifier
            .fillMaxHeight()
            .clip(PillShape)
            .background(if (selected) PeeringColors.ink else Color.Transparent)
            .selectable(selected = selected, role = Role.Tab, onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterHorizontally),
    ) {
        Icon(tab.icon(), contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
        Text(stringResource(tab.titleRes()), style = PeeringText.subheadlineSemibold.copy(fontSize = 13.sp), color = tint, maxLines = 1)
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
