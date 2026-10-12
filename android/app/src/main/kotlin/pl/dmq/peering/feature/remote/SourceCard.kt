package pl.dmq.peering.feature.remote

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.rememberDecodedBitmap
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.wire.fromBase64

/** A capture source as an outlined card: its live picture on top, then its app icon, name and a line of detail. */
@Composable
fun SourceCard(tile: SourceTile, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val shape = peeringShapes.medium
    val outline = if (tile.selected) BorderStroke(2.dp, PeeringColors.accent) else BorderStroke(1.dp, PeeringColors.outline)
    Column(
        modifier = modifier
            .clip(shape)
            .border(outline, shape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { selected = tile.selected },
    ) {
        SourcePreview(tile)
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            SourceIcon(tile)
            Column(Modifier.weight(1f)) {
                Text(
                    text = tile.title,
                    style = MaterialTheme.typography.bodyMedium,
                    color = PeeringColors.ink,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = detail(tile),
                    style = MaterialTheme.typography.bodySmall,
                    color = PeeringColors.muted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (tile.selected) {
                Icon(
                    imageVector = AppIcons.checkCircle,
                    contentDescription = stringResource(R.string.sources_showing),
                    tint = PeeringColors.accent,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}

@Composable
private fun SourcePreview(tile: SourceTile) {
    val thumbnail = tile.thumbnail
    val key = thumbnail?.let { "thumb:${tile.source.stableId}:${it.jpegData.contentHashCode()}" }
    val picture by rememberDecodedBitmap(key) { thumbnail?.jpegData }
    Box(
        modifier = Modifier.fillMaxWidth().aspectRatio(PREVIEW_ASPECT).background(PeeringColors.containerHigh),
        contentAlignment = Alignment.Center,
    ) {
        val bitmap = picture
        if (bitmap != null) {
            Image(
                bitmap = bitmap,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Icon(tile.kind.placeholder(), contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(32.dp))
        }
    }
}

@Composable
private fun SourceIcon(tile: SourceTile) {
    val data = tile.iconData
    val icon by rememberDecodedBitmap(data?.let { "icon:${it.hashCode()}" }) { data?.fromBase64() }
    val bitmap = icon
    if (tile.kind != CaptureSourceKind.DISPLAY && bitmap != null) {
        Image(bitmap = bitmap, contentDescription = null, modifier = Modifier.size(28.dp).clip(peeringShapes.extraSmall))
    } else {
        Icon(tile.kind.placeholder(), contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(28.dp))
    }
}

@Composable
private fun detail(tile: SourceTile): String {
    val resolution = stringResource(R.string.sources_resolution, tile.pixelSize.width.toInt(), tile.pixelSize.height.toInt())
    return if (tile.kind == CaptureSourceKind.DISPLAY) resolution else tile.subtitle ?: resolution
}

private fun CaptureSourceKind.placeholder(): ImageVector = when (this) {
    CaptureSourceKind.DISPLAY -> AppIcons.display
    CaptureSourceKind.APPLICATION -> AppIcons.grid
    CaptureSourceKind.WINDOW -> AppIcons.window
}

private const val PREVIEW_ASPECT = 16f / 10f
