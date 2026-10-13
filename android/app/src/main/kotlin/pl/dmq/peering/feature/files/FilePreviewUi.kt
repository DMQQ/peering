package pl.dmq.peering.feature.files

import pl.dmq.peering.wire.RemoteFileKind

/** The preview as the screen draws it. [path] is the file being shown, whatever its content. */
data class FilePreviewUi(
    val path: String,
    val content: PreviewContent,
    val download: DownloadStatus,
    val wraps: Boolean,
    val canShare: Boolean,
) {
    val canWrap: Boolean get() = content is PreviewContent.Text
}

sealed interface PreviewContent {
    data class Loading(val fraction: Double?) : PreviewContent

    data class Text(
        val lines: List<String>,
        val shownBytes: Long,
        val totalBytes: Long,
        val isTruncated: Boolean,
        val showsLineNumbers: Boolean = false,
    ) : PreviewContent

    data class Markdown(
        val blocks: List<MarkdownBlock>,
        val shownBytes: Long,
        val totalBytes: Long,
        val isTruncated: Boolean,
    ) : PreviewContent

    /** The bytes of a picture, decoded by the screen; the presenter does not decode them. */
    class Image(val bytes: ByteArray) : PreviewContent

    /** A PDF the computer sent whole, drawn by the system's renderer. */
    class Pdf(val bytes: ByteArray) : PreviewContent

    data object Empty : PreviewContent

    /** A picture or document cut at the cap, which cannot be drawn in part. */
    data class TooLarge(val totalBytes: Long) : PreviewContent

    /** The file is not something this screen draws: text that is not UTF-8, or a kind it has no viewer for. */
    data class Unsupported(val kind: RemoteFileKind?) : PreviewContent

    data class Failed(val message: String) : PreviewContent
}

/** A file handed to the system's share sheet. */
class ShareRequest(val name: String, val bytes: ByteArray, val mimeType: String)

sealed interface DownloadStatus {
    data object Idle : DownloadStatus

    data class Running(val fraction: Double?, val isZipping: Boolean, val sourcePath: String) : DownloadStatus

    data object Finished : DownloadStatus

    data class Failed(val problem: DownloadProblem) : DownloadStatus
}

sealed interface DownloadProblem {
    data object TooLarge : DownloadProblem

    data object ShortRead : DownloadProblem

    data class Transfer(val message: String) : DownloadProblem

    /** The destination the user chose could not be opened or written. */
    data object Destination : DownloadProblem
}
