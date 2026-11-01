package pl.dmq.peering.ui.wiring

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import pl.dmq.peering.DebugLog
import pl.dmq.peering.feature.files.DownloadSink
import pl.dmq.peering.feature.files.GalleryStore
import java.io.IOException
import java.io.OutputStream

/** A download written to a document the user chose in the system picker, or to an item reserved in the gallery. */
internal class SafDownloadSink private constructor(
    private val resolver: ContentResolver,
    private val uri: Uri,
    private val output: OutputStream,
) : DownloadSink {
    override fun write(bytes: ByteArray) = output.write(bytes)

    /** A commit that fails leaves nothing behind: a gallery item that cannot be published would stay hidden forever. */
    override fun commit() {
        try {
            output.close()
            if (GalleryStore.isGalleryItem(uri)) GalleryStore.publish(resolver, uri)
        } catch (failure: Exception) {
            discard()
            throw failure
        }
    }

    override fun discard() {
        try {
            output.close()
        } catch (failure: Exception) {
            DebugLog.w(TAG, { "closing the discarded download failed" }, failure)
        }
        try {
            if (GalleryStore.isGalleryItem(uri)) resolver.delete(uri, null, null) else DocumentsContract.deleteDocument(resolver, uri)
        } catch (failure: Exception) {
            DebugLog.w(TAG, { "deleting the discarded download failed" }, failure)
        }
    }

    companion object {
        @Throws(IOException::class)
        fun open(resolver: ContentResolver, uri: Uri): SafDownloadSink {
            val output = resolver.openOutputStream(uri, "w") ?: throw IOException("the chosen document cannot be written")
            return SafDownloadSink(resolver, uri, output)
        }
    }
}

private const val TAG = "PeeringDownload"
