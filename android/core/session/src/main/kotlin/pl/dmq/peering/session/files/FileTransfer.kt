package pl.dmq.peering.session.files

/** The one download the browser is running, or the outcome of the last one. */
sealed class FileTransfer {
    data object Idle : FileTransfer()

    data class Running(val plan: FileDownloadPlan) : FileTransfer()

    /** [expectedMd5] is what the Mac read, for the writer to check the finished file against; null when it sent none. */
    data class Finished(val sourcePath: String, val expectedMd5: String? = null) : FileTransfer()

    data class Failed(val sourcePath: String, val reason: DownloadFailure) : FileTransfer()
}
