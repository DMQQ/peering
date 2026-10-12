package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceKind
import pl.dmq.peering.wire.PixelSize
import pl.dmq.peering.wire.SourceThumbnail

/** One capture source the user can pick, with the text, app icon and picture the host gave for it. */
data class SourceTile(
    val source: CaptureSource,
    val kind: CaptureSourceKind,
    val title: String,
    val subtitle: String?,
    val pixelSize: PixelSize,
    val selected: Boolean,
    /** The app icon as the host sent it: PNG bytes in base64. Decoded only when the tile is drawn. */
    val iconData: String?,
    val thumbnail: SourceThumbnail?,
)
