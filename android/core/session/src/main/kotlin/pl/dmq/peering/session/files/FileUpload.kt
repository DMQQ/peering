package pl.dmq.peering.session.files

/** The one upload the browser is running, or how the last one ended. */
sealed class FileUpload {
    data object Idle : FileUpload()

    data class Running(val path: String, val sentBytes: Long, val totalBytes: Long) : FileUpload() {
        val fraction: Double get() = if (totalBytes <= 0) 0.0 else sentBytes.toDouble() / totalBytes
    }

    data class Done(val path: String) : FileUpload()

    data class Failed(val path: String, val reason: UploadFailure) : FileUpload()
}

sealed interface UploadFailure {
    data object TooLarge : UploadFailure

    /** The phone could not read the file it was sending. */
    data object Unreadable : UploadFailure

    data object InvalidName : UploadFailure

    /** The computer's own text. */
    data class Host(val message: String) : UploadFailure
}
