package pl.dmq.peering.session.files

/** The outcome the Mac reports for one upload. [message] is the Mac's own text. */
sealed class UploadOutcome {
    abstract val path: String

    data class Written(override val path: String, val totalBytes: Long) : UploadOutcome()

    data class Failed(override val path: String, val message: String) : UploadOutcome()
}
