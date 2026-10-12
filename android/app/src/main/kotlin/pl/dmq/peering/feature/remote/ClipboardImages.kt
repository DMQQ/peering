package pl.dmq.peering.feature.remote

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File

/** The picture side of the clipboard: bytes in and out of the phone's clipboard, off the main thread. */
internal object ClipboardImages {
    private const val PNG_TYPE = "image/png"
    private const val PNG_QUALITY = 100

    /**
     * The picture a clipboard URI names as PNG. A PNG is sent as it is, anything else is decoded and re-encoded. Null
     * when the source cannot be read. A result over the wire cap is returned whole, so the caller can say how large it was.
     */
    suspend fun readPng(context: Context, uri: Uri): ByteArray? = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        try {
            if (resolver.getType(uri) == PNG_TYPE) {
                resolver.openInputStream(uri)?.use { it.readBytes() }
            } else {
                resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }?.let(::encode)
            }
        } catch (error: java.io.IOException) {
            null
        } catch (error: SecurityException) {
            null
        }
    }

    /** Writes [png] into the app's shared cache and returns the content URI the clipboard can name. */
    suspend fun share(context: Context, png: ByteArray): Uri = withContext(Dispatchers.IO) {
        val directory = File(context.cacheDir, "shared").also { it.mkdirs() }
        val file = File(directory, "clipboard-${png.contentHashCode()}.png")
        if (!file.exists()) file.writeBytes(png)
        FileProvider.getUriForFile(context, "${context.packageName}.shared", file)
    }

    /** A small bitmap for a history row, at most [maxEdge] pixels on its longer side. */
    suspend fun thumbnail(png: ByteArray, maxEdge: Int): Bitmap? = withContext(Dispatchers.IO) {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(png, 0, png.size, bounds)
        val longest = maxOf(bounds.outWidth, bounds.outHeight)
        if (longest <= 0) return@withContext null
        var sample = 1
        while (longest / (sample * 2) >= maxEdge) sample *= 2
        BitmapFactory.decodeByteArray(png, 0, png.size, BitmapFactory.Options().apply { inSampleSize = sample })
    }

    private fun encode(bitmap: Bitmap): ByteArray = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, PNG_QUALITY, it) }.toByteArray()
}
