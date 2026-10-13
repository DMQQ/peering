package pl.dmq.peering.feature.remote

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.pressable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/**
 * Chrome over a mosaic: the lines where one window's picture stops and the next starts, each window's name, and a button
 * to take it out. Only the buttons take touches; the rest passes through to the canvas, which handles the long press.
 */
@Composable
internal fun MosaicOverlay(tiles: List<OverlayTile>, onRemove: (Int) -> Unit, modifier: Modifier = Modifier) {
    val density = LocalDensity.current
    Box(modifier.fillMaxSize()) {
        Canvas(Modifier.fillMaxSize()) {
            tiles.sortedBy { it.held }.forEach { tile ->
                val emphasised = tile.held || tile.target
                drawRect(
                    color = if (tile.target) PeeringColors.accent else Color.White.copy(alpha = if (tile.held) 0.9f else 0.22f),
                    topLeft = Offset(tile.rect.left.toFloat(), tile.rect.top.toFloat()),
                    size = Size(tile.rect.width.toFloat(), tile.rect.height.toFloat()),
                    style = Stroke(width = (if (emphasised) 2.dp else 1.dp).toPx()),
                )
            }
        }
        tiles.forEach { tile ->
            val left = with(density) { tile.rect.left.toFloat().toDp() }
            val top = with(density) { tile.rect.top.toFloat().toDp() }
            val width = with(density) { tile.rect.width.toFloat().toDp() }
            if (tile.showsTitle && tile.title != null) {
                val room = if (tile.showsClose) width - TITLE_INSET * 2 - CLOSE_SIZE - CLOSE_INSET else width - TITLE_INSET * 2
                Text(
                    tile.title,
                    style = PeeringText.caption2,
                    color = Color.White,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .offset(left + TITLE_INSET, top + TITLE_INSET)
                        .widthIn(max = room)
                        .wrapTitle(),
                )
            }
            if (tile.showsClose) {
                Box(
                    Modifier
                        .offset(left + width - CLOSE_INSET - CLOSE_SIZE, top + CLOSE_INSET)
                        .size(CLOSE_SIZE)
                        .clip(CircleShape)
                        .background(PeeringColors.containerHigh)
                        .pressable({ onRemove(tile.index) }),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        AppIcons.close,
                        contentDescription = stringResource(R.string.mosaic_tile_remove, tile.title ?: stringResource(R.string.mosaic_tile_window)),
                        tint = PeeringColors.ink,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
        }
    }
}

private fun Modifier.wrapTitle(): Modifier =
    clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)).padding(horizontal = 5.dp, vertical = 2.dp)

private val TITLE_INSET = 6.dp
private val CLOSE_SIZE = 28.dp
private val CLOSE_INSET = 8.dp
