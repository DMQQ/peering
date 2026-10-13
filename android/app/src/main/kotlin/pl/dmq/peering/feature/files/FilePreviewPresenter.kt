package pl.dmq.peering.feature.files

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.session.files.FilePreview
import pl.dmq.peering.session.files.FileTransfer
import pl.dmq.peering.wire.RemoteFileKind

/**
 * The file open in the preview. Text waits for every byte, since a partial file cannot be read; an image waits the same
 * way. The download the preview's file belongs to is shown beside it, whichever screen started it.
 *
 * Download asks for a destination first ([destinationRequest]); the screen opens the system picker and reports the
 * document back through [destinationChosen], and only then does the download start. Share does the same through
 * [shareRequest].
 */
class FilePreviewPresenter(
    private val port: FileBrowsingPort,
    scope: CoroutineScope,
) {
    private val pendingPath = MutableStateFlow<String?>(null)
    private val destinationPath = MutableStateFlow<String?>(null)
    private val wrapChoice = MutableStateFlow<Pair<String, Boolean>?>(null)
    private val pendingShare = MutableStateFlow<ShareRequest?>(null)

    /** The file whose destination the screen should ask for, or null while no picker is due. */
    val destinationRequest: StateFlow<String?> = pendingPath.asStateFlow()

    /** The file to hand to the share sheet, or null while none is due. */
    val shareRequest: StateFlow<ShareRequest?> = pendingShare.asStateFlow()

    val ui: StateFlow<FilePreviewUi?> = combine(
        port.state,
        port.destinationFailed,
        destinationPath,
        wrapChoice,
    ) { browser, failed, path, wrap ->
        derive(browser, failed && path == browser.preview?.path, wrap)
    }.stateIn(scope, SharingStarted.Eagerly, derive(port.state.value, false, null))

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

    fun toggleWrap() {
        val current = ui.value ?: return
        wrapChoice.value = current.path to !current.wraps
    }

    fun share() {
        val preview = port.state.value.preview ?: return
        if (!preview.isComplete || preview.isTruncated || preview.failure != null) return
        pendingShare.value = ShareRequest(FilePath.name(preview.path), preview.contents, MimeTypes.of(preview.path))
    }

    fun shareHandled() = pendingShare.update { null }

    fun cancelDownload() = port.cancelDownload()

    fun close() = port.closePreview()

    private fun derive(browser: FileBrowserState, destinationFailed: Boolean, wrap: Pair<String, Boolean>?): FilePreviewUi? {
        val preview = browser.preview ?: return null
        val content = content(preview)
        return FilePreviewUi(
            path = preview.path,
            content = content,
            download = download(browser.transfer, preview.path, destinationFailed),
            wraps = wrap?.takeIf { it.first == preview.path }?.second ?: wrapsByDefault(preview.path),
            canShare = preview.isComplete && !preview.isTruncated && preview.failure == null,
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
            RemoteFileKind.IMAGE ->
                if (preview.isTruncated) PreviewContent.TooLarge(preview.totalBytes ?: 0L) else PreviewContent.Image(preview.contents)
            RemoteFileKind.PDF ->
                if (preview.isTruncated) PreviewContent.TooLarge(preview.totalBytes ?: 0L) else PreviewContent.Pdf(preview.contents)
            else -> PreviewContent.Unsupported(preview.kind)
        }
    }

    private fun textContent(preview: FilePreview): PreviewContent {
        val lines = TextPreview.lines(preview.contents) ?: return PreviewContent.Unsupported(RemoteFileKind.TEXT)
        if (preview.contents.isEmpty()) return PreviewContent.Empty
        val shown = preview.contents.size.toLong()
        val total = preview.totalBytes ?: shown
        val extension = FileGlyph.extensionOf(FilePath.name(preview.path))
        if (extension in MARKDOWN_EXTENSIONS) {
            return PreviewContent.Markdown(MarkdownBlocks.parse(lines.joinToString("\n")), shown, total, preview.isTruncated)
        }
        return PreviewContent.Text(
            lines = lines,
            shownBytes = shown,
            totalBytes = total,
            isTruncated = preview.isTruncated,
            showsLineNumbers = !wrapsByDefault(preview.path),
        )
    }

    /** Prose reads wrapped; code and data read better with the lines as written. */
    private fun wrapsByDefault(path: String): Boolean {
        val glyph = FileGlyph.byName(FilePath.name(path))
        return glyph != FileGlyph.CODE && FileGlyph.extensionOf(FilePath.name(path)) !in DATA_EXTENSIONS
    }

    private fun download(transfer: FileTransfer, path: String, destinationFailed: Boolean): DownloadStatus =
        DownloadStatuses.of(transfer, path)
            ?: if (destinationFailed) DownloadStatus.Failed(DownloadProblem.Destination) else DownloadStatus.Idle

    private companion object {
        val MARKDOWN_EXTENSIONS = setOf("md", "markdown")
        val DATA_EXTENSIONS = setOf("json", "csv", "tsv", "log", "xml", "plist", "yaml", "yml", "toml", "ini")
    }
}
