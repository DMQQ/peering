package pl.dmq.peering.ui.wiring

import android.content.ContentResolver
import android.graphics.Bitmap
import android.net.Uri
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import pl.dmq.peering.feature.agents.attach.AttachmentOutcome
import pl.dmq.peering.feature.agents.attach.AttachmentSender
import pl.dmq.peering.feature.agents.attach.AttachmentSource
import pl.dmq.peering.feature.agents.attach.PhotoName
import pl.dmq.peering.feature.files.InputChunks
import pl.dmq.peering.imaging.BoundedBitmap
import pl.dmq.peering.session.agent.attachmentPath
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.session.files.FileUpload
import pl.dmq.peering.session.files.TransferLimits
import pl.dmq.peering.session.files.UploadFailure
import pl.dmq.peering.session.ports.Clock

/** Chat attachments over the session's file browser: documents are sent as they are, photos as a JPEG. */
internal class SessionAttachments(
    private val browser: FileBrowser,
    private val resolver: ContentResolver,
    private val clock: Clock,
) : AttachmentSender {
    override suspend fun send(source: AttachmentSource, folder: String, onNamed: (String) -> Unit): AttachmentOutcome =
        withContext(Dispatchers.IO) {
            when (source) {
                is AttachmentSource.Document -> sendDocument(Uri.parse(source.uri), folder, onNamed)
                is AttachmentSource.Photo -> sendPhoto(Uri.parse(source.uri), folder, onNamed)
            }
        }

    private suspend fun sendDocument(uri: Uri, folder: String, onNamed: (String) -> Unit): AttachmentOutcome {
        val document = SafUploadSource.query(resolver, uri)
            ?: return AttachmentOutcome.Failed(uri.lastPathSegment.orEmpty(), UploadFailure.Unreadable)
        onNamed(document.name)
        try {
            document.open().use { input ->
                browser.uploadInto(folder, document.name, document.size, InputChunks(input, TransferLimits.UPLOAD_CHUNK_BYTES))
            }
        } catch (failure: IOException) {
            return AttachmentOutcome.Failed(document.name, UploadFailure.Unreadable)
        }
        val thumbnail = uri.toString().takeIf { resolver.getType(uri)?.startsWith("image/") == true }
        return outcome(document.name, folder, thumbnail)
    }

    private suspend fun sendPhoto(uri: Uri, folder: String, onNamed: (String) -> Unit): AttachmentOutcome {
        val name = PhotoName.of(clock.unixSeconds() * MILLIS_PER_SECOND)
        onNamed(name)
        val jpeg = try {
            jpegOf(uri)
        } catch (failure: IOException) {
            null
        } catch (failure: OutOfMemoryError) {
            null
        } ?: return AttachmentOutcome.Failed(name, UploadFailure.Unreadable)
        browser.uploadInto(folder, name, jpeg.size.toLong(), InputChunks(ByteArrayInputStream(jpeg), TransferLimits.UPLOAD_CHUNK_BYTES))
        return outcome(name, folder, uri.toString())
    }

    /** A library photo is often HEIC or WebP, which the agents cannot read, so anything that is not a JPEG is re-encoded as one. */
    private fun jpegOf(uri: Uri): ByteArray? {
        val limit = TransferLimits.MAXIMUM_PHONE_UPLOAD_BYTES.toInt()
        val bytes = resolver.openInputStream(uri)?.use { it.readNBytes(limit + 1) }?.takeIf { it.size <= limit } ?: return null
        if (resolver.getType(uri) == "image/jpeg") return bytes
        val bitmap = BoundedBitmap.decode(bytes) ?: return null
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, it) }.toByteArray()
    }

    private fun outcome(name: String, folder: String, thumbnailUri: String?): AttachmentOutcome =
        when (val upload = browser.state.value.upload) {
            is FileUpload.Done -> AttachmentOutcome.Sent(name, attachmentPath(folder, name), thumbnailUri)
            is FileUpload.Failed -> AttachmentOutcome.Failed(name, upload.reason)
            else -> AttachmentOutcome.Failed(name, UploadFailure.Unreadable)
        }

    private companion object {
        const val JPEG_QUALITY = 90
        const val MILLIS_PER_SECOND = 1_000L
    }
}
