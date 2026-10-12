package pl.dmq.peering.feature.remote

import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringListItem
import pl.dmq.peering.ui.theme.PeeringColors

/** One capture source as a two line list item: its name, then the host's subtitle and its resolution. */
@Composable
fun SourceTileRow(tile: SourceTile, onClick: () -> Unit) {
    val resolution = stringResource(R.string.sources_resolution, tile.pixelSize.width.toInt(), tile.pixelSize.height.toInt())
    PeeringListItem(
        headline = tile.title,
        supporting = tile.subtitle ?: resolution,
        onClick = onClick,
        role = Role.Button,
        bleed = false,
        modifier = Modifier.semantics { selected = tile.selected },
        trailing = if (tile.selected) {
            { Icon(AppIcons.check, contentDescription = stringResource(R.string.sources_showing), tint = PeeringColors.accent) }
        } else {
            null
        },
    )
}
