package pl.dmq.peering.ui.kit

import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.produceState
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import pl.dmq.peering.imaging.BoundedBitmap

private const val CACHE_BYTES = 8 * 1024 * 1024

private val bitmaps = object : LruCache<String, ImageBitmap>(CACHE_BYTES) {
    override fun sizeOf(key: String, value: ImageBitmap): Int = value.width * value.height * 4
}

/**
 * Decodes an encoded image off the main thread and remembers it by [key], so a list that scrolls or a sheet that
 * reopens does not decode again. [key] must change whenever the picture does. Null while decoding or when it cannot be read.
 */
@Composable
fun rememberDecodedBitmap(key: String?, bytes: () -> ByteArray?): State<ImageBitmap?> =
    produceState<ImageBitmap?>(initialValue = key?.let(bitmaps::get), key) {
        if (key == null) {
            value = null
            return@produceState
        }
        value = bitmaps.get(key) ?: withContext(Dispatchers.Default) {
            bytes()?.let(BoundedBitmap::decode)?.asImageBitmap()
        }?.also { bitmaps.put(key, it) }
    }
