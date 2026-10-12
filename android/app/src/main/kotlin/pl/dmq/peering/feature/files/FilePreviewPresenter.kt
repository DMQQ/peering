package pl.dmq.peering.feature.files

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.session.files.DownloadFailure
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.session.files.FilePreview
import pl.dmq.peering.session.files.FileTransfer
import pl.dmq.peering.wire.RemoteFileKind

/**
 * The file open in the preview. Text waits for every byte, since a partial file cannot be read; an image waits the same
 * way. The download the preview's file belongs to is shown beside it, whichever screen started it.
 */
class FilePreviewPresenter(
    private val port: FileBrowsingPort,
    scope: CoroutineScope,
) {
    val ui: StateFlow<FilePreviewUi?> = port.state
        .map { derive(it) }
        .stateIn(scope, SharingStarted.Eagerly, derive(port.state.value))

    fun download() {
        val path = port.state.value.preview?.path ?: return
        port.download(path)
    }

    fun cancelDownload() = port.cancelDownload()

    fun close() = port.closePreview()

    private fun derive(browser: FileBrowserState): FilePreviewUi? {
        val preview = browser.preview ?: return null
        return FilePreviewUi(
            path = preview.path,
            content = content(preview),
            download = download(browser.transfer, preview.path),
        )
    }

    private fun content(preview: FilePreview): PreviewContent {
        preview.failure?.let { return PreviewContent.Failed(it) }
        if (!preview.isComplete) {
            val total = preview.totalBytes
            return PreviewContent.Loading(total?.takeIf { it > 0 }?.let { preview.contents.size.toDouble() / it })
        }
        return when (preview.kind) {
            RemoteFileKind.TEXT -> textContent(preview)
            RemoteFileKind.IMAGE -> PreviewContent.Image(preview.contents)
            else -> PreviewContent.Unsupported(preview.kind)
        }
    }

    private fun textContent(preview: FilePreview): PreviewContent {
        val lines = TextPreview.lines(preview.contents) ?: return PreviewContent.Unsupported(RemoteFileKind.TEXT)
        return PreviewContent.Text(
            lines = lines,
            shownBytes = preview.contents.size.toLong(),
            totalBytes = preview.totalBytes ?: preview.contents.size.toLong(),
            isTruncated = preview.isTruncated,
        )
    }

    private fun download(transfer: FileTransfer, path: String): DownloadStatus = when (transfer) {
        is FileTransfer.Running ->
            if (transfer.plan.sourcePath == path) {
                DownloadStatus.Running(transfer.plan.progress, transfer.plan.isZipping)
            } else {
                DownloadStatus.Idle
            }
        is FileTransfer.Finished -> if (transfer.sourcePath == path) DownloadStatus.Finished else DownloadStatus.Idle
        is FileTransfer.Failed ->
            if (transfer.sourcePath == path) DownloadStatus.Failed(problem(transfer.reason)) else DownloadStatus.Idle
        FileTransfer.Idle -> DownloadStatus.Idle
    }

    private fun problem(reason: DownloadFailure): DownloadProblem = when (reason) {
        DownloadFailure.TooLarge -> DownloadProblem.TooLarge
        DownloadFailure.ShortRead -> DownloadProblem.ShortRead
        is DownloadFailure.Transfer -> DownloadProblem.Transfer(reason.message)
    }
}
