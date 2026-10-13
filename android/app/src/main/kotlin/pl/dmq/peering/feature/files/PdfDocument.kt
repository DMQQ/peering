package pl.dmq.peering.feature.files

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** The size a page is drawn at for a given width: its own shape, held to a height a bitmap can have. */
internal object PdfPageSize {
    private const val MAX_HEIGHT = 8_192

    fun heightFor(widthPx: Int, pageWidth: Int, pageHeight: Int): Int {
        if (pageWidth <= 0 || pageHeight <= 0) return widthPx
        return (widthPx.toLong() * pageHeight / pageWidth).toInt().coerceIn(1, MAX_HEIGHT)
    }
}

/**
 * A PDF the computer sent whole, drawn one page at a time by the system's renderer. The renderer reads a file, so the
 * bytes are written to the cache first. It opens one page at a time, so pages are drawn one after another.
 */
internal class PdfDocument private constructor(
    private val renderer: PdfRenderer,
    private val descriptor: ParcelFileDescriptor,
    private val file: File,
) {
    private val oneAtATime = Mutex()

    val pageCount: Int get() = renderer.pageCount

    suspend fun render(index: Int, widthPx: Int): Bitmap = oneAtATime.withLock {
        withContext(Dispatchers.Default) {
            renderer.openPage(index).use { page ->
                val bitmap = Bitmap.createBitmap(widthPx, PdfPageSize.heightFor(widthPx, page.width, page.height), Bitmap.Config.ARGB_8888)
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                bitmap
            }
        }
    }

    suspend fun close() = oneAtATime.withLock {
        renderer.close()
        descriptor.close()
        file.delete()
    }

    companion object {
        /** Null when the bytes are not a PDF this device can open, such as one that needs a password. */
        suspend fun open(directory: File, bytes: ByteArray): PdfDocument? = withContext(Dispatchers.IO) {
            val file = File.createTempFile("preview", ".pdf", directory.also { it.mkdirs() })
            try {
                file.writeBytes(bytes)
                val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                try {
                    PdfDocument(PdfRenderer(descriptor), descriptor, file)
                } catch (failure: IOException) {
                    descriptor.close()
                    throw failure
                }
            } catch (failure: IOException) {
                file.delete()
                null
            } catch (failure: SecurityException) {
                file.delete()
                null
            } catch (failure: IllegalArgumentException) {
                file.delete()
                null
            }
        }
    }
}
