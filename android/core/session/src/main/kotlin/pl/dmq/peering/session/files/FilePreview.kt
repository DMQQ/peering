package pl.dmq.peering.session.files

import pl.dmq.peering.wire.RemoteFileKind

/**
 * A file opened for viewing. [contents] grows one piece at a time from offset 0. A piece past the cap for its
 * kind is dropped, so [isTruncated] is true when the bytes held fall short of [totalBytes].
 */
data class FilePreview(
    val path: String,
    val kind: RemoteFileKind? = null,
    val contents: ByteArray = ByteArray(0),
    val totalBytes: Long? = null,
    val isComplete: Boolean = false,
    val failure: String? = null,
) {
    val isLoading: Boolean get() = failure == null && !isComplete

    val isTruncated: Boolean get() = isComplete && (totalBytes ?: 0L) > contents.size

    companion object {
        const val TEXT_BYTE_LIMIT = 1024 * 1024
        const val DRAWN_BYTE_LIMIT = 8 * 1024 * 1024

        fun byteLimit(kind: RemoteFileKind): Int =
            if (kind == RemoteFileKind.TEXT) TEXT_BYTE_LIMIT else DRAWN_BYTE_LIMIT
    }
}
