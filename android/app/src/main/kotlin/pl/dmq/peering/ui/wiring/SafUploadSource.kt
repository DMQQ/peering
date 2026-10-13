package pl.dmq.peering.ui.wiring

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import java.io.IOException
import java.io.InputStream

/** A document the user picked to send: its display name, its size, and a way to read it. */
internal class SafUploadSource private constructor(
    val name: String,
    val size: Long,
    private val resolver: ContentResolver,
    private val uri: Uri,
) {
    @Throws(IOException::class)
    fun open(): InputStream = resolver.openInputStream(uri) ?: throw IOException("the chosen document cannot be read")

    companion object {
        /** Null when the document has no name or no known size, since a transfer declares its size up front. */
        fun query(resolver: ContentResolver, uri: Uri): SafUploadSource? {
            val (name, size) = try {
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                    if (!cursor.moveToFirst()) return null
                    val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                    cursor.getString(0) to if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) cursor.getLong(sizeColumn) else -1L
                } ?: return null
            } catch (failure: SecurityException) {
                return null
            }
            if (name.isNullOrBlank() || size < 0) return null
            return SafUploadSource(name, size, resolver, uri)
        }
    }
}
