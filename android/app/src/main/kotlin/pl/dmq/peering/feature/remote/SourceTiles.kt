package pl.dmq.peering.feature.remote

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.rememberDecodedBitmap
import pl.dmq.peering.ui.kit.pressable
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.wire.fromBase64

/** A shape bound: an extreme window would otherwise draw as a sliver. */
private const val MIN_SHAPE = 0.4f
private const val MAX_SHAPE = 2.5f
private const val DEFAULT_SHAPE = 1.6f

/** The height every picture tile is drawn at; its width follows the shape of what it shows. */
val TILE_HEIGHT: Dp = 98.dp

/** A picture of a screen or window with its name and owner under it, outlined in the blue while it is the one on screen. */
@Composable
internal fun PreviewTile(tile: SourceTile, onClick: () -> Unit, modifier: Modifier = Modifier, badge: Int? = null) {
    val live = tile.selected && badge == null
    val shape = (tile.thumbnail?.let { it.width.toFloat() / it.height } ?: pixelShape(tile)).coerceIn(MIN_SHAPE, MAX_SHAPE)
    val width = TILE_HEIGHT * shape
    Column(
        modifier
            .width(width)
            .pressable(onClick)
            .semantics {
                selected = tile.selected
                contentDescription = listOfNotNull(tile.title, tile.subtitle).joinToString(", ")
            },
    ) {
        Box(
            Modifier
                .size(width, TILE_HEIGHT)
                .clip(peeringShapes.extraSmall)
                .background(PeeringColors.surface)
                .border(
                    if (tile.selected) BorderStroke(2.dp, PeeringColors.accent) else BorderStroke(1.dp, PeeringColors.ink.copy(alpha = 0.18f)),
                    peeringShapes.extraSmall,
                ),
            contentAlignment = Alignment.Center,
        ) {
            TilePicture(tile)
            badge?.let { PlaceBadge(it, Modifier.align(Alignment.TopEnd).padding(4.dp)) }
        }
        Text(
            tile.title,
            style = PeeringText.caption2.copy(fontSize = 10.sp, fontWeight = if (live) FontWeight.SemiBold else FontWeight.Normal),
            color = if (live) PeeringColors.accent else PeeringColors.ink,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        tile.subtitle?.let {
            Text(it, style = PeeringText.caption2.copy(fontSize = 9.sp), color = PeeringColors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** The place a picked tile will take in a mosaic. */
@Composable
internal fun PlaceBadge(place: Int, modifier: Modifier = Modifier) {
    Box(modifier.size(18.dp).background(PeeringColors.accent, CircleShape), contentAlignment = Alignment.Center) {
        Text(place.toString(), style = PeeringText.caption2.copy(fontSize = 10.sp, fontWeight = FontWeight.Bold), color = PeeringColors.ink)
    }
}

private fun pixelShape(tile: SourceTile): Float {
    val size = tile.pixelSize
    return if (size.width > 0 && size.height > 0) (size.width / size.height).toFloat() else DEFAULT_SHAPE
}

@Composable
private fun TilePicture(tile: SourceTile) {
    val thumbnail = tile.thumbnail
    val key = thumbnail?.let { "thumb:${tile.source.stableId}:${it.jpegData.contentHashCode()}" }
    val picture by rememberDecodedBitmap(key) { thumbnail?.jpegData }
    val bitmap = picture
    if (bitmap != null) {
        Image(bitmap = bitmap, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
    } else {
        Icon(tile.kind.placeholder(), contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(28.dp))
    }
}

/** An application's mark at [size], or a plain glyph while the computer has sent none. */
@Composable
internal fun ApplicationIcon(data: String?, size: Dp, fallback: ImageVector = AppIcons.grid) {
    val icon by rememberDecodedBitmap(data?.let { "icon:${it.hashCode()}" }) { data?.fromBase64() }
    val bitmap = icon
    if (bitmap != null) {
        Image(bitmap = bitmap, contentDescription = null, modifier = Modifier.size(size).clip(peeringShapes.extraSmall))
    } else {
        Icon(fallback, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(size))
    }
}

/** Dashed and empty: a place a tile could be. Tapping it makes one. */
@Composable
internal fun AddTile(label: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val line = PeeringColors.ink.copy(alpha = 0.18f)
    Box(
        modifier
            .size(TILE_HEIGHT * 0.75f, TILE_HEIGHT)
            .clip(peeringShapes.extraSmall)
            .tappable(onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            drawRoundRect(
                color = line,
                cornerRadius = CornerRadius(12.dp.toPx()),
                style = Stroke(width = 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()))),
            )
        }
        Icon(SessionIcons.add, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(22.dp))
    }
}

private fun CaptureSourceKind.placeholder(): ImageVector = when (this) {
    CaptureSourceKind.DISPLAY -> AppIcons.display
    CaptureSourceKind.APPLICATION -> AppIcons.grid
    CaptureSourceKind.WINDOW -> AppIcons.window
}
