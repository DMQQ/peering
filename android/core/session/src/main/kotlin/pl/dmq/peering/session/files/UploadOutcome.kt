package pl.dmq.peering.session.files

/** The outcome the Mac reports for one upload. [message] is the Mac's own text. */
sealed class UploadOutcome {
    data class Written(val path: String, val totalBytes: Long) : UploadOutcome()

    data class Failed(val path: String, val message: String) : UploadOutcome()
}
