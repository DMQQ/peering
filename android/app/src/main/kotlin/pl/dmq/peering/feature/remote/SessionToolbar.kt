package pl.dmq.peering.feature.remote

import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes

/** The session controls as Material's own navigation bar in portrait and navigation rail in landscape. */
@Composable
fun SessionToolbar(
    actions: List<ToolbarAction>,
    keyboardShown: Boolean,
    mode: InputMode,
    vertical: Boolean,
    onAction: (ToolbarAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (vertical) {
        NavigationRail(modifier = modifier.clip(peeringShapes.extraLarge), containerColor = PeeringColors.containerHigh) {
            actions.forEach { action ->
                NavigationRailItem(
                    selected = action == ToolbarAction.KEYBOARD && keyboardShown,
                    onClick = { onAction(action) },
                    icon = { Icon(action.icon(mode), contentDescription = null) },
                    label = { Text(stringResource(action.labelRes(mode))) },
                    colors = NavigationRailItemDefaults.colors(indicatorColor = PeeringColors.selectedIndicator),
                )
            }
        }
    } else {
        NavigationBar(modifier = modifier.clip(peeringShapes.extraLarge), containerColor = PeeringColors.containerHigh) {
            actions.forEach { action ->
                NavigationBarItem(
                    selected = action == ToolbarAction.KEYBOARD && keyboardShown,
                    onClick = { onAction(action) },
                    icon = { Icon(action.icon(mode), contentDescription = null) },
                    label = { Text(stringResource(action.labelRes(mode))) },
                    colors = NavigationBarItemDefaults.colors(indicatorColor = PeeringColors.selectedIndicator),
                )
            }
        }
    }
}

private fun ToolbarAction.icon(mode: InputMode): ImageVector = when (this) {
    ToolbarAction.KEYBOARD -> AppIcons.keyboard
    ToolbarAction.POINTER_MODE -> if (mode == InputMode.TRACKPAD) AppIcons.trackpad else AppIcons.tap
    ToolbarAction.FIT -> AppIcons.fit
    ToolbarAction.SOURCES -> AppIcons.display
    ToolbarAction.QUALITY -> AppIcons.tune
    ToolbarAction.MENU -> AppIcons.menu
}

private fun ToolbarAction.labelRes(mode: InputMode): Int = when (this) {
    ToolbarAction.KEYBOARD -> R.string.remote_keyboard
    ToolbarAction.POINTER_MODE ->
        if (mode == InputMode.TRACKPAD) R.string.remote_pointer_trackpad else R.string.remote_pointer_touch
    ToolbarAction.FIT -> R.string.remote_fit
    ToolbarAction.SOURCES -> R.string.hub_sources
    ToolbarAction.QUALITY -> R.string.hub_quality
    ToolbarAction.MENU -> R.string.remote_menu
}
