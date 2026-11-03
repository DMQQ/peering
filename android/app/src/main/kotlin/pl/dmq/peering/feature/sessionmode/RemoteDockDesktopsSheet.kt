package pl.dmq.peering.feature.sessionmode

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.pressable
import pl.dmq.peering.ui.kit.rememberDecodedBitmap
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.SpaceDisplay
import pl.dmq.peering.wire.fromBase64

/** Every desktop of every display as a picture; a tap moves the computer to it and closes the sheet. Opening asks for fresh pictures. */
@Composable
fun RemoteDockDesktopsSheet(catalog: CaptureCatalog?, onOpen: () -> Unit, onSwitch: (SpaceDisplay, Int) -> Unit, onDismiss: () -> Unit) {
    LaunchedEffect(Unit) { onOpen() }
    val sections = DesktopSheetSections.of(catalog)
    PeeringSheet(onDismiss) {
        LazyVerticalGrid(
            GridCells.Adaptive(140.dp),
            Modifier.fillMaxWidth().padding(horizontal = 18.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) { SheetHeader(stringResource(R.string.dock_desktops), null) }
            for (section in sections) {
                section.title?.let { title ->
                    item(span = { GridItemSpan(maxLineSpan) }) { Text(title, style = PeeringText.subheadline, color = PeeringColors.muted) }
                }
                items((1..section.display.count).toList()) { index ->
                    DesktopSheetTile(section.display, index) {
                        onSwitch(section.display, index)
                        onDismiss()
                    }
                }
            }
        }
    }
}

@Composable
private fun DesktopSheetTile(display: SpaceDisplay, index: Int, onClick: () -> Unit) {
    val here = display.current == index
    val title = if (here) stringResource(R.string.sources_desktop_here, index) else stringResource(R.string.sources_desktop, index)
    Column(
        Modifier.fillMaxWidth().pressable(onClick).semantics {
            selected = here
            contentDescription = title
        },
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        DesktopPicture(display, index, here)
        Text(
            title,
            style = PeeringText.footnote.copy(fontWeight = if (here) FontWeight.SemiBold else FontWeight.Normal),
            color = if (here) PeeringColors.ink else PeeringColors.muted,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** A desktop never visited since the host started has no picture, and gets a dashed outline rather than one of a desktop that does not exist. */
@Composable
private fun DesktopPicture(display: SpaceDisplay, index: Int, here: Boolean) {
    val preview = display.preview(index)
    val picture by rememberDecodedBitmap(preview?.let { "desktop:${display.displayId}-$index:${it.jpegBase64.hashCode()}" }) { preview?.jpegBase64?.fromBase64() }
    val shape = peeringShapes.extraSmall
    val frame = Modifier.fillMaxWidth().aspectRatio(DESKTOP_SHAPE).clip(shape)
    val bitmap = picture
    if (bitmap == null) {
        val line = PeeringColors.ink.copy(alpha = if (here) 0.5f else 0.18f)
        Canvas(frame) {
            drawOutline(
                shape.createOutline(size, layoutDirection, this),
                color = line,
                style = Stroke(width = 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()))),
            )
        }
        return
    }
    val outline = if (here) BorderStroke(2.dp, PeeringColors.ink.copy(alpha = 0.7f)) else BorderStroke(1.dp, PeeringColors.ink.copy(alpha = 0.18f))
    Box(frame.border(outline, shape)) {
        Image(bitmap = bitmap, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
    }
}

private const val DESKTOP_SHAPE = 16f / 10f
