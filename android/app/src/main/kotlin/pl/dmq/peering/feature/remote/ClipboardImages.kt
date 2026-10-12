package pl.dmq.peering.feature.remote

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import pl.dmq.peering.imaging.BoundedBitmap
import pl.dmq.peering.imaging.SharedFiles
import pl.dmq.peering.wire.MAX_CLIPBOARD_IMAGE_BYTES

sealed interface ImageRead {
    class Png(val bytes: ByteArray) : ImageRead

    /** The source is over the clipboard picture cap, at [bytes] long or more. */
    data class TooLarge(val bytes: Int) : ImageRead

    data object Unreadable : ImageRead
}

/** The picture side of the clipboard: bytes in and out of the phone's clipboard, off the main thread. */
internal object ClipboardImages {
    private const val PNG_TYPE = "image/png"
    private const val PNG_QUALITY = 100

    /**
     * The picture a clipboard URI names as PNG. A PNG is sent as it is, anything else is decoded within a pixel budget
     * and re-encoded. The size is checked before any bytes are read, so a huge source costs no memory.
     */
    suspend fun readPng(context: Context, uri: Uri): ImageRead = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        try {
            val declared = resolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: return@withContext ImageRead.Unreadable
            if (declared > MAX_CLIPBOARD_IMAGE_BYTES) return@withContext ImageRead.TooLarge(declared.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
            val bytes = resolver.openInputStream(uri)?.use { it.readNBytes(MAX_CLIPBOARD_IMAGE_BYTES + 1) }
                ?: return@withContext ImageRead.Unreadable
            when {
                bytes.size > MAX_CLIPBOARD_IMAGE_BYTES -> ImageRead.TooLarge(bytes.size)
                resolver.getType(uri) == PNG_TYPE -> ImageRead.Png(bytes)
                else -> BoundedBitmap.decode(bytes)?.let { ImageRead.Png(encode(it)) } ?: ImageRead.Unreadable
            }
        } catch (error: java.io.IOException) {
            ImageRead.Unreadable
        } catch (error: SecurityException) {
            ImageRead.Unreadable
        } catch (error: OutOfMemoryError) {
            ImageRead.Unreadable
        }
    }

    /** Writes [png] into the app's shared cache and returns the content URI the clipboard can name. */
    suspend fun share(context: Context, png: ByteArray): Uri = withContext(Dispatchers.IO) {
        val file = SharedFiles.write(File(context.cacheDir, "shared"), png, "png")
        FileProvider.getUriForFile(context, "${context.packageName}.shared", file)
    }

    /** A small bitmap for a history row, at most [maxEdge] pixels on its longer side. */
    suspend fun thumbnail(png: ByteArray, maxEdge: Int): Bitmap? = withContext(Dispatchers.IO) { BoundedBitmap.thumbnail(png, maxEdge) }

    private fun encode(bitmap: Bitmap): ByteArray = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, PNG_QUALITY, it) }.toByteArray()
}
