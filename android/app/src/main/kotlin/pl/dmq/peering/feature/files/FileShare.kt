package pl.dmq.peering.feature.files

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File
import java.io.IOException

/** Hands a previewed file to the system's share sheet through a copy in the cache that only the receiver may read. */
object FileShare {
    /** False when the copy could not be written. */
    fun share(context: Context, request: ShareRequest, chooserTitle: String): Boolean {
        val directory = File(context.cacheDir, SHARED_DIRECTORY)
        val copy = File(directory, request.name)
        try {
            directory.mkdirs()
            copy.writeBytes(request.bytes)
        } catch (failure: IOException) {
            return false
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.shared", copy)
        val send = Intent(Intent.ACTION_SEND)
            .setType(request.mimeType)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(Intent.createChooser(send, chooserTitle).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return true
    }

    private const val SHARED_DIRECTORY = "shared"
}
