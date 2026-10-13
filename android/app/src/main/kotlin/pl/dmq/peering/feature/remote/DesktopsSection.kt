package pl.dmq.peering.feature.remote

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.pressable
import pl.dmq.peering.ui.kit.rememberDecodedBitmap
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.SpaceDisplay
import pl.dmq.peering.wire.SpaceInfo
import pl.dmq.peering.wire.fromBase64

/** What the desktop rows need to know of the screen: which one the picture shows, and the desktop a tap has asked for. */
internal class DesktopContext(
    val info: SpaceInfo,
    val chosen: CaptureSource?,
    val pending: PendingDesktop?,
    val onSwitch: (SpaceDisplay, Int) -> Unit,
)

/** The desktops of one screen, a row of pictures; a name above them when [namesScreen] says the row needs one. */
@Composable
internal fun ScreenDesktops(descriptor: CaptureSourceDescriptor, display: SpaceDisplay, context: DesktopContext) {
    val showing = descriptor.source == context.chosen
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (namesScreen(context.info.displays.size, showing, display)) ScreenChip(descriptor.title, showing)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (index in 1..display.count) {
                DesktopTile(display, index, descriptor, showing, context)
            }
        }
    }
}

@Composable
private fun ScreenChip(name: String, showing: Boolean) {
    Row(
        Modifier
            .background(if (showing) PeeringColors.accent.copy(alpha = 0.25f) else PeeringColors.surface, CircleShape)
            .border(BorderStroke(1.dp, PeeringColors.ink.copy(alpha = if (showing) 0f else 0.15f)), CircleShape)
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (showing) Icon(AppIcons.check, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(11.dp))
        Text(name, style = PeeringText.caption2.copy(fontSize = 10.sp, fontWeight = FontWeight.SemiBold), color = PeeringColors.ink, maxLines = 1)
    }
}

/** A picture, because "which one had my browser" is not answerable by a number. A desktop never visited since the host started has none, and stays empty rather than picturing one that does not exist. */
@Composable
private fun DesktopTile(display: SpaceDisplay, index: Int, screen: CaptureSourceDescriptor, showing: Boolean, context: DesktopContext) {
    val current = desktopIsCurrent(display, index, context.pending)
    val live = desktopIsLive(showing, display, index, context.pending)
    val preview = display.preview(index)
    val shape = (preview?.shape ?: screenShape(screen)).coerceIn(MIN_DESKTOP_SHAPE, MAX_DESKTOP_SHAPE)
    val picture by rememberDecodedBitmap(preview?.let { "desktop:${display.displayId}-$index:${it.jpegBase64.hashCode()}" }) { preview?.jpegBase64?.fromBase64() }
    val width = TILE_HEIGHT * shape
    val title = if (live) stringResource(R.string.sources_desktop_here, index) else stringResource(R.string.sources_desktop, index)
    Column(
        Modifier.width(width).pressable({ context.onSwitch(display, index) }).semantics {
            selected = live
            contentDescription = title
        },
    ) {
        Box(
            Modifier
                .size(width, TILE_HEIGHT)
                .clip(peeringShapes.extraSmall)
                .background(PeeringColors.surface)
                .border(
                    when {
                        live -> BorderStroke(2.dp, PeeringColors.accent)
                        current -> BorderStroke(1.5.dp, PeeringColors.ink.copy(alpha = 0.5f))
                        else -> BorderStroke(1.dp, PeeringColors.ink.copy(alpha = 0.18f))
                    },
                    peeringShapes.extraSmall,
                ),
            contentAlignment = Alignment.Center,
        ) {
            val bitmap = picture
            if (bitmap != null) {
                Image(bitmap = bitmap, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            } else {
                Icon(AppIcons.spaces, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(22.dp))
            }
        }
        Text(
            title,
            style = PeeringText.caption2.copy(fontSize = 10.sp, fontWeight = if (live) FontWeight.SemiBold else FontWeight.Normal),
            color = when {
                live -> PeeringColors.accent
                current -> PeeringColors.ink
                else -> PeeringColors.muted
            },
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** The screen's shape before its desktop's own picture arrives, so the tile does not change shape. */
private fun screenShape(screen: CaptureSourceDescriptor): Float {
    val size = screen.pixelSize
    return if (size.width > 0 && size.height > 0) (size.width / size.height).toFloat() else DEFAULT_DESKTOP_SHAPE
}

private const val MIN_DESKTOP_SHAPE = 0.4f
private const val MAX_DESKTOP_SHAPE = 2.5f
private const val DEFAULT_DESKTOP_SHAPE = 1.6f

/** Gives the pending mark up when the computer has not answered in time: a refused switch leaves the list as it was, so nothing in it would. */
@Composable
internal fun PendingDesktopTimeout(pending: PendingDesktop?, onExpired: () -> Unit) {
    LaunchedEffect(pending) {
        if (pending != null) {
            delay(PendingDesktop.TIMEOUT_MILLIS)
            onExpired()
        }
    }
}

/** The desktops change under the user, so while the panel shows them the computer is asked for fresh pictures. Window pictures are another request. */
@Composable
internal fun DesktopRefresh(showing: Boolean, presenter: SourcesPresenter) {
    LaunchedEffect(showing) {
        while (showing) {
            presenter.refreshDesktops()
            delay(DESKTOP_REFRESH_MILLIS)
        }
    }
}

private const val DESKTOP_REFRESH_MILLIS = 4_000L
