package pl.dmq.peering.session.files

/** The one download the browser is running, or the outcome of the last one. */
sealed class FileTransfer {
    data object Idle : FileTransfer()

    data class Running(val plan: FileDownloadPlan) : FileTransfer()

    data class Finished(val sourcePath: String) : FileTransfer()

    data class Failed(val sourcePath: String, val reason: DownloadFailure) : FileTransfer()
}
