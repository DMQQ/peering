package pl.dmq.peering.feature.files

import pl.dmq.peering.wire.RemoteFileKind

/** The preview as the screen draws it. [path] is the file being shown, whatever its content. */
data class FilePreviewUi(
    val path: String,
    val content: PreviewContent,
    val download: DownloadStatus,
)

sealed interface PreviewContent {
    data class Loading(val fraction: Double?) : PreviewContent

    data class Text(
        val lines: List<String>,
        val shownBytes: Long,
        val totalBytes: Long,
        val isTruncated: Boolean,
    ) : PreviewContent

    /** The bytes of a picture, decoded by the screen; the presenter does not decode them. */
    class Image(val bytes: ByteArray) : PreviewContent

    /** The file is not something this screen draws: text that is not UTF-8, or a kind it has no viewer for. */
    data class Unsupported(val kind: RemoteFileKind?) : PreviewContent

    data class Failed(val message: String) : PreviewContent
}

sealed interface DownloadStatus {
    data object Idle : DownloadStatus

    data class Running(val fraction: Double?, val isZipping: Boolean) : DownloadStatus

    data object Finished : DownloadStatus

    data class Failed(val problem: DownloadProblem) : DownloadStatus
}

sealed interface DownloadProblem {
    data object TooLarge : DownloadProblem

    data object ShortRead : DownloadProblem

    data class Transfer(val message: String) : DownloadProblem
}
