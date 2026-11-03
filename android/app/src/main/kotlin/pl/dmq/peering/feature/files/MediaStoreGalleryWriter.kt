package pl.dmq.peering.feature.files

import android.content.Context
import android.widget.Toast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import pl.dmq.peering.DebugLog
import pl.dmq.peering.R
import java.io.IOException

/** The gallery through MediaStore. Holds the application context, so it outlives the screen that asked. */
internal class MediaStoreGalleryWriter(context: Context) : GalleryWriter {
    private val context = context.applicationContext

    override suspend fun write(target: GalleryTarget, bytes: ByteArray): Boolean =
        withContext(Dispatchers.IO) { GalleryStore.write(context.contentResolver, target, bytes) }

    override suspend fun reserve(target: GalleryTarget): String? = withContext(Dispatchers.IO) {
        try {
            GalleryStore.reserve(context.contentResolver, target).toString()
        } catch (failure: IOException) {
            DebugLog.w(TAG, { "reserving a gallery item failed" }, failure)
            null
        }
    }

    override fun report(saved: Boolean) {
        val message = if (saved) R.string.preview_saved_to_photos else R.string.preview_save_to_photos_failed
        Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
    }
}

private const val TAG = "PeeringGallery"
