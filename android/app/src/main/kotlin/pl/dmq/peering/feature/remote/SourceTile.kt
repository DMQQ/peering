package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.PixelSize

/** One capture source the user can pick, with the text the host gave for it. */
data class SourceTile(
    val source: CaptureSource,
    val title: String,
    val subtitle: String?,
    val pixelSize: PixelSize,
    val selected: Boolean,
)
