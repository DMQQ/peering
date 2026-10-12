package pl.dmq.peering.feature.remote

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors

@Composable
fun SourceTileRow(tile: SourceTile, onClick: () -> Unit) {
    OutlinedPanel(
        modifier = Modifier
            .fillMaxWidth()
            .clip(MaterialTheme.shapes.large)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { selected = tile.selected },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = tile.title,
                    style = MaterialTheme.typography.titleMedium,
                    color = PeeringColors.ink,
                )
                tile.subtitle?.let {
                    Text(text = it, style = MaterialTheme.typography.bodySmall, color = PeeringColors.muted)
                }
                Text(
                    text = stringResource(
                        R.string.sources_resolution,
                        tile.pixelSize.width.toInt(),
                        tile.pixelSize.height.toInt(),
                    ),
                    style = MaterialTheme.typography.labelMedium,
                    color = PeeringColors.faint,
                )
            }
            if (tile.selected) {
                Text(
                    text = stringResource(R.string.sources_showing),
                    style = MaterialTheme.typography.labelMedium,
                    color = PeeringColors.accent,
                )
            }
        }
    }
}
