package pl.dmq.peering.feature.remote

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes

/**
 * The session's bottom action bar: icon over a one-line label, every item at least 48 dp square and sharing the width
 * equally. A column on the screen's end in landscape. Labels never wrap: they are short and cut with an ellipsis.
 */
@Composable
fun SessionActionBar(
    actions: List<ToolbarAction>,
    keyboardShown: Boolean,
    vertical: Boolean,
    onAction: (ToolbarAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier,
        shape = peeringShapes.large,
        color = PeeringColors.containerHigh,
        shadowElevation = 6.dp,
    ) {
        if (vertical) {
            Column(Modifier.padding(4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                actions.forEach { ActionItem(it, it == ToolbarAction.KEYBOARD && keyboardShown, Modifier.widthIn(min = 72.dp), onAction) }
            }
        } else {
            Row(Modifier.fillMaxWidth().padding(4.dp)) {
                actions.forEach { ActionItem(it, it == ToolbarAction.KEYBOARD && keyboardShown, Modifier.weight(1f), onAction) }
            }
        }
    }
}

@Composable
private fun ActionItem(
    action: ToolbarAction,
    selected: Boolean,
    modifier: Modifier,
    onAction: (ToolbarAction) -> Unit,
) {
    val label = stringResource(action.labelRes())
    Column(
        modifier = modifier
            .heightIn(min = 56.dp)
            .clip(peeringShapes.medium)
            .clickable(role = Role.Button) { onAction(action) }
            .padding(horizontal = 4.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
    ) {
        Icon(
            imageVector = action.icon(),
            contentDescription = null,
            tint = if (selected) PeeringColors.accent else PeeringColors.ink,
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = if (selected) PeeringColors.accent else PeeringColors.muted,
            maxLines = 1,
            softWrap = false,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )
    }
}

private fun ToolbarAction.icon(): ImageVector = when (this) {
    ToolbarAction.KEYBOARD -> AppIcons.keyboard
    ToolbarAction.SOURCES -> AppIcons.display
    ToolbarAction.AGENTS -> AppIcons.sparkles
    ToolbarAction.FILES -> AppIcons.folder
    ToolbarAction.MORE -> AppIcons.more
}

private fun ToolbarAction.labelRes(): Int = when (this) {
    ToolbarAction.KEYBOARD -> R.string.remote_keyboard
    ToolbarAction.SOURCES -> R.string.hub_sources
    ToolbarAction.AGENTS -> R.string.hub_agents
    ToolbarAction.FILES -> R.string.hub_files
    ToolbarAction.MORE -> R.string.remote_more
}
