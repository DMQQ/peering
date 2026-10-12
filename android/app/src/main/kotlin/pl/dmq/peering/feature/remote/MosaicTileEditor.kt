package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.video.MosaicArrangement
import pl.dmq.peering.session.video.MosaicChoice
import pl.dmq.peering.session.video.MosaicEdit
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.rowSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.wire.CaptureCatalog

/** One tile of the mosaic on screen as the editor lists it, with what each of its controls can still do. */
data class EditorTile(
    val index: Int,
    val title: String?,
    val weight: Int,
    val canMoveUp: Boolean,
    val canMoveDown: Boolean,
    val canShrink: Boolean,
    val canGrow: Boolean,
)

/** The editor's rows for [arrangement]; a title is null where the catalogue no longer lists the window. */
fun editorTiles(arrangement: MosaicArrangement, catalog: CaptureCatalog?): List<EditorTile> {
    val known = catalog?.let { it.displays + it.applications + it.windows }.orEmpty()
    val last = arrangement.choices.lastIndex
    return arrangement.choices.mapIndexed { index, choice ->
        EditorTile(
            index = index,
            title = known.firstOrNull { it.source == choice.source }?.title,
            weight = choice.weight,
            canMoveUp = index > 0,
            canMoveDown = index < last,
            canShrink = choice.weight > MosaicChoice.MINIMUM_WEIGHT,
            canGrow = choice.weight < MosaicChoice.MAXIMUM_WEIGHT,
        )
    }
}

/** Reorder, resize and remove, a tile to a row. Each press asks the computer for the new arrangement at once. */
@Composable
internal fun MosaicTileEditor(tiles: List<EditorTile>, onEdit: (MosaicEdit) -> Unit) {
    Column(Modifier.fillMaxWidth().rowSurface().padding(horizontal = 8.dp, vertical = 4.dp)) {
        tiles.forEach { tile ->
            val name = tile.title ?: stringResource(R.string.mosaic_tile_unknown)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    name,
                    style = PeeringText.subheadlineMedium,
                    color = PeeringColors.ink,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f).padding(end = 4.dp),
                )
                EditorButton(AppIcons.arrowUp, stringResource(R.string.mosaic_tile_earlier, name), tile.canMoveUp) {
                    onEdit(MosaicEdit.Move(tile.index, tile.index - 1))
                }
                EditorButton(AppIcons.arrowDown, stringResource(R.string.mosaic_tile_later, name), tile.canMoveDown) {
                    onEdit(MosaicEdit.Move(tile.index, tile.index + 1))
                }
                EditorButton(AppIcons.shrink, stringResource(R.string.mosaic_tile_smaller, name), tile.canShrink) {
                    onEdit(MosaicEdit.Resize(tile.index, -1))
                }
                EditorButton(AppIcons.grow, stringResource(R.string.mosaic_tile_larger, name), tile.canGrow) {
                    onEdit(MosaicEdit.Resize(tile.index, 1))
                }
                EditorButton(AppIcons.close, stringResource(R.string.mosaic_tile_remove, name), true) {
                    onEdit(MosaicEdit.Remove(tile.index))
                }
            }
        }
    }
}

@Composable
private fun EditorButton(icon: androidx.compose.ui.graphics.vector.ImageVector, description: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(40.dp).alpha(if (enabled) 1f else 0.3f).tappable(onClick, enabled = enabled),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = description, tint = PeeringColors.ink, modifier = Modifier.size(18.dp))
    }
}
