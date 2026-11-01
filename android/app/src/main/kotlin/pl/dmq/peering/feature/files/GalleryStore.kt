package pl.dmq.peering.feature.files

import android.content.ContentResolver
import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import java.io.IOException

/** Writes into the phone's gallery through MediaStore, which needs no storage permission for the app's own items. */
object GalleryStore {
    /** A gallery item hidden until [publish] makes it visible, so a half-written file never shows in Photos. */
    @Throws(IOException::class)
    fun reserve(resolver: ContentResolver, target: GalleryTarget): Uri {
        val collection = if (target.isVideo) VIDEOS else IMAGES
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, target.displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, target.mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, target.relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            // The system deletes a pending item past its expiry, so one orphaned by a dead process does not stay hidden forever.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                put(MediaStore.MediaColumns.DATE_EXPIRES, System.currentTimeMillis() / 1000 + PENDING_LIFETIME_SECONDS)
            }
        }
        return resolver.insert(collection, values) ?: throw IOException("the gallery refused a new item")
    }

    /** Deletes a reserved item that will not be filled. */
    fun remove(resolver: ContentResolver, uri: Uri) {
        resolver.delete(uri, null, null)
    }

    /**
     * Deletes this app's items still pending from an earlier process. Run at launch, before any download can have
     * reserved one, since every pending item then belongs to a process that died mid download.
     */
    fun deleteStalePending(resolver: ContentResolver, packageName: String) {
        for (collection in listOf(IMAGES, VIDEOS)) {
            val ids = pendingIds(resolver, collection, packageName)
            ids.forEach { id -> resolver.delete(Uri.withAppendedPath(collection, id.toString()), null, null) }
        }
    }

    private fun pendingIds(resolver: ContentResolver, collection: Uri, packageName: String): List<Long> {
        val selection = "${MediaStore.MediaColumns.IS_PENDING} = 1 AND ${MediaStore.MediaColumns.OWNER_PACKAGE_NAME} = ?"
        val projection = arrayOf(MediaStore.MediaColumns._ID)
        val cursor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val arguments = Bundle().apply {
                putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, arrayOf(packageName))
                putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
            }
            resolver.query(collection, projection, arguments, null)
        } else {
            @Suppress("DEPRECATION")
            resolver.query(MediaStore.setIncludePending(collection), projection, selection, arrayOf(packageName), null)
        }
        return cursor?.use { rows -> buildList { while (rows.moveToNext()) add(rows.getLong(0)) } }.orEmpty()
    }

    fun isGalleryItem(uri: Uri): Boolean = uri.authority == MediaStore.AUTHORITY

    fun publish(resolver: ContentResolver, uri: Uri) {
        resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
    }

    /** False when the item could not be written; nothing half-written is left behind. */
    fun write(resolver: ContentResolver, target: GalleryTarget, bytes: ByteArray): Boolean {
        val uri = try {
            reserve(resolver, target)
        } catch (failure: IOException) {
            return false
        }
        return try {
            val output = resolver.openOutputStream(uri, "w") ?: throw IOException("the gallery item cannot be written")
            output.use { it.write(bytes) }
            publish(resolver, uri)
            true
        } catch (failure: Exception) {
            resolver.delete(uri, null, null)
            false
        }
    }

    private val IMAGES: Uri get() = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    private val VIDEOS: Uri get() = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    private const val PENDING_LIFETIME_SECONDS = 24L * 60 * 60
}
