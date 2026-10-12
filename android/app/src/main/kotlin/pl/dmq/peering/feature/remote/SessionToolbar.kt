package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes

/**
 * The session controls as a floating toolbar of 48 dp icon buttons, a row in portrait and a column in landscape.
 * Icon only so six actions fit at any width and font scale; the name shows as a tooltip on long press.
 */
@Composable
fun SessionToolbar(
    actions: List<ToolbarAction>,
    keyboardShown: Boolean,
    mode: InputMode,
    vertical: Boolean,
    onAction: (ToolbarAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(modifier = modifier, shape = peeringShapes.extraLarge, color = PeeringColors.containerHigh, shadowElevation = 6.dp) {
        val buttons: @Composable () -> Unit = {
            actions.forEach { action ->
                ToolbarButton(action, mode, selected = action == ToolbarAction.KEYBOARD && keyboardShown, onClick = { onAction(action) })
            }
        }
        if (vertical) {
            Column(Modifier.padding(4.dp)) { buttons() }
        } else {
            Row(Modifier.padding(4.dp)) { buttons() }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ToolbarButton(action: ToolbarAction, mode: InputMode, selected: Boolean, onClick: () -> Unit) {
    val label = stringResource(action.labelRes(mode))
    TooltipBox(
        positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(),
        tooltip = { PlainTooltip { Text(label) } },
        state = rememberTooltipState(),
    ) {
        IconButton(
            onClick = onClick,
            colors = IconButtonDefaults.iconButtonColors(
                containerColor = if (selected) PeeringColors.selectedIndicator else Color.Transparent,
                contentColor = PeeringColors.ink,
            ),
        ) {
            Icon(action.icon(mode), contentDescription = label)
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
