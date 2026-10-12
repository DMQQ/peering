package pl.dmq.peering.feature.files

import pl.dmq.peering.session.files.DownloadFailure
import pl.dmq.peering.session.files.FileTransfer

internal object DownloadStatuses {
    /** The status of the transfer when it belongs to [path] (any path when null), else null. */
    fun of(transfer: FileTransfer, path: String?): DownloadStatus? = when (transfer) {
        is FileTransfer.Running -> transfer.plan.takeIf { path == null || it.sourcePath == path }
            ?.let { DownloadStatus.Running(it.progress, it.isZipping, it.sourcePath) }
        is FileTransfer.Finished -> DownloadStatus.Finished.takeIf { path == null || transfer.sourcePath == path }
        is FileTransfer.Failed -> transfer.takeIf { path == null || it.sourcePath == path }
            ?.let { DownloadStatus.Failed(problem(it.reason)) }
        FileTransfer.Idle -> null
    }

    private fun problem(reason: DownloadFailure): DownloadProblem = when (reason) {
        DownloadFailure.TooLarge -> DownloadProblem.TooLarge
        DownloadFailure.ShortRead -> DownloadProblem.ShortRead
        is DownloadFailure.Transfer -> DownloadProblem.Transfer(reason.message)
    }
}
