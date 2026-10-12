package pl.dmq.peering.feature.agents.attach

import pl.dmq.peering.session.files.UploadFailure

/** What the person picked to attach: any document, or a picture from the photo picker. */
sealed interface AttachmentSource {
    val uri: String

    data class Document(override val uri: String) : AttachmentSource

    data class Photo(override val uri: String) : AttachmentSource
}

sealed interface AttachmentOutcome {
    /** [path] is where the file now sits on the computer. [thumbnailUri] is set for a picture, so the chip can show it. */
    data class Sent(val name: String, val path: String, val thumbnailUri: String? = null) : AttachmentOutcome

    data class Failed(val name: String, val reason: UploadFailure) : AttachmentOutcome
}

/** Sends one picked file into a chat's folder on the computer. Null where the computer cannot receive files. */
interface AttachmentSender {
    /** [onNamed] is told the file's name as soon as it is known, before the bytes go. */
    suspend fun send(source: AttachmentSource, folder: String, onNamed: (String) -> Unit): AttachmentOutcome
}
