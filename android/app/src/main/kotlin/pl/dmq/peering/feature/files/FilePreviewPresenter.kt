package pl.dmq.peering.feature.files

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.session.files.DownloadFailure
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.session.files.FilePreview
import pl.dmq.peering.session.files.FileTransfer
import pl.dmq.peering.wire.RemoteFileKind

/**
 * The file open in the preview. Text waits for every byte, since a partial file cannot be read; an image waits the same
 * way. The download the preview's file belongs to is shown beside it, whichever screen started it.
 *
 * Download asks for a destination first ([destinationRequest]); the screen opens the system picker and reports the
 * document back through [destinationChosen], and only then does the download start.
 */
class FilePreviewPresenter(
    private val port: FileBrowsingPort,
    scope: CoroutineScope,
) {
    private val pendingPath = MutableStateFlow<String?>(null)
    private val destinationPath = MutableStateFlow<String?>(null)

    /** The file whose destination the screen should ask for, or null while no picker is due. */
    val destinationRequest: StateFlow<String?> = pendingPath.asStateFlow()

    val ui: StateFlow<FilePreviewUi?> = combine(port.state, port.destinationFailed, destinationPath) { browser, failed, path ->
        derive(browser, failed && path == browser.preview?.path)
    }.stateIn(scope, SharingStarted.Eagerly, derive(port.state.value, false))

    fun download() {
        val path = port.state.value.preview?.path ?: return
        pendingPath.value = path
    }

    /** The document the user picked, or null when they backed out of the picker. */
    fun destinationChosen(uri: String?) {
        val path = pendingPath.value ?: return
        pendingPath.value = null
        if (uri == null) return
        destinationPath.value = path
        port.download(path, uri)
    }

    fun cancelDownload() = port.cancelDownload()

    fun close() = port.closePreview()

    private fun derive(browser: FileBrowserState, destinationFailed: Boolean): FilePreviewUi? {
        val preview = browser.preview ?: return null
        return FilePreviewUi(
            path = preview.path,
            content = content(preview),
            download = download(browser.transfer, preview.path, destinationFailed),
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

    private fun download(transfer: FileTransfer, path: String, destinationFailed: Boolean): DownloadStatus {
        val ownStatus = when (transfer) {
            is FileTransfer.Running -> transfer.plan.takeIf { it.sourcePath == path }
                ?.let { DownloadStatus.Running(it.progress, it.isZipping) }
            is FileTransfer.Finished -> DownloadStatus.Finished.takeIf { transfer.sourcePath == path }
            is FileTransfer.Failed -> transfer.takeIf { it.sourcePath == path }
                ?.let { DownloadStatus.Failed(problem(it.reason)) }
            FileTransfer.Idle -> null
        }
        return ownStatus ?: if (destinationFailed) DownloadStatus.Failed(DownloadProblem.Destination) else DownloadStatus.Idle
    }

    private fun problem(reason: DownloadFailure): DownloadProblem = when (reason) {
        DownloadFailure.TooLarge -> DownloadProblem.TooLarge
        DownloadFailure.ShortRead -> DownloadProblem.ShortRead
        is DownloadFailure.Transfer -> DownloadProblem.Transfer(reason.message)
    }
}
