package pl.dmq.peering.ui.wiring

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import pl.dmq.peering.feature.files.DownloadSink
import java.io.IOException
import java.io.OutputStream

/** A download written to a document the user chose in the system picker, which the Storage Access Framework opens. */
internal class SafDownloadSink private constructor(
    private val resolver: ContentResolver,
    private val uri: Uri,
    private val output: OutputStream,
) : DownloadSink {
    override fun write(bytes: ByteArray) = output.write(bytes)

    override fun commit() = output.close()

    override fun discard() {
        try {
            output.close()
        } finally {
            DocumentsContract.deleteDocument(resolver, uri)
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
