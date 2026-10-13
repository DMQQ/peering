package pl.dmq.peering.feature.files

import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import pl.dmq.peering.imaging.BoundedBitmap

/** Decodes a picture's bytes for drawing. Null when the platform cannot read them or there is no memory for them. */
object ImageBitmapDecoder {
    fun decode(bytes: ByteArray): ImageBitmap? = BoundedBitmap.decode(bytes)?.asImageBitmap()
}
