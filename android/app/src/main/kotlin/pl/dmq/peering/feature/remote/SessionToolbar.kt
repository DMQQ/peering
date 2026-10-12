package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.chipSurface
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
    val shape = peeringShapes.extraLarge
    if (vertical) {
        Column(
            modifier = modifier.chipSurface(shape).padding(vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) { items() }
    } else {
        Row(
            modifier = modifier.chipSurface(shape).padding(horizontal = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) { items() }
    }
}

@Composable
private fun ToolbarButton(icon: ImageVector, label: String, selected: Boolean, onClick: () -> Unit) {
    val tint = if (selected) PeeringColors.accent else PeeringColors.ink
    Box(
        modifier = Modifier
            .clip(peeringShapes.large)
            .tappable(onClick, role = Role.Button)
            .semantics { this.selected = selected }
            .defaultMinSize(minWidth = 56.dp, minHeight = 56.dp)
            .padding(horizontal = 6.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(imageVector = icon, contentDescription = null, tint = tint)
            Text(text = label, style = MaterialTheme.typography.labelSmall, color = tint, maxLines = 1)
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
