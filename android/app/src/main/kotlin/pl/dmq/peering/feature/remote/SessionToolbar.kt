package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes

/** The session controls: a bar along the bottom in portrait, a rail down the end edge in landscape. */
@Composable
fun SessionToolbar(
    actions: List<ToolbarAction>,
    keyboardShown: Boolean,
    mode: InputMode,
    vertical: Boolean,
    onAction: (ToolbarAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    val items: @Composable () -> Unit = {
        actions.forEach { action ->
            ToolbarButton(
                icon = action.icon(mode),
                label = stringResource(action.labelRes(mode)),
                selected = action == ToolbarAction.KEYBOARD && keyboardShown,
                onClick = { onAction(action) },
            )
        }
    }
    Surface(
        modifier = modifier,
        shape = peeringShapes.extraLarge,
        color = PeeringColors.containerHigh,
        shadowElevation = 6.dp,
    ) {
        if (vertical) {
            Column(
                modifier = Modifier.padding(vertical = 8.dp, horizontal = 4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) { items() }
        } else {
            Row(
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) { items() }
        }
    }
}

/** One destination in the way Material's navigation bar draws it: the icon on an indicator pill, a label under it. */
@Composable
private fun ToolbarButton(icon: ImageVector, label: String, selected: Boolean, onClick: () -> Unit) {
    Column(
        modifier = Modifier
            .clip(peeringShapes.large)
            .tappable(onClick, role = Role.Button)
            .semantics { this.selected = selected }
            .defaultMinSize(minWidth = 64.dp)
            .padding(horizontal = 4.dp, vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier
                .size(width = 56.dp, height = 30.dp)
                .clip(CircleShape)
                .background(if (selected) PeeringColors.selectedIndicator else Color.Transparent),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (selected) PeeringColors.ink else PeeringColors.muted,
                modifier = Modifier.size(24.dp),
            )
        }
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = if (selected) PeeringColors.ink else PeeringColors.muted,
            maxLines = 1,
        )
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
