package pl.dmq.peering.session.files

import pl.dmq.peering.wire.TerminalRequest

/**
 * One download of a file, or of a folder the Mac zips first. [readPath] is the file being read: the source itself,
 * or the zip once the Mac has made it. Each piece names its offset, so pieces may arrive out of order.
 */
data class FileDownloadPlan(
    val sessionID: String,
    val sourcePath: String,
    val isFolder: Boolean,
    val readPath: String?,
    val window: FileDownloadWindow = FileDownloadWindow(),
) {
    /** Zipping on the Mac has not finished, so no piece can be asked for yet. */
    val isZipping: Boolean get() = readPath == null

    val progress: Double? get() = window.fraction

    /** The first request: a zip for a folder, or the first piece of the file itself. */
    fun start(): Pair<FileDownloadPlan, TerminalRequest> {
        if (isFolder) return this to TerminalRequest.ArchiveFolder(sessionID, sourcePath)
        val (nextWindow, offset) = window.first()
        return copy(window = nextWindow) to TerminalRequest.ReadRange(sessionID, sourcePath, offset)
    }

    /** The Mac has made the zip; start reading it. Ignored unless it is this folder's zip. */
    fun onArchiveReady(folder: String, archivePath: String): DownloadStep {
        if (!isFolder || folder != sourcePath) return DownloadStep.Ignored
        val (nextWindow, offset) = window.first()
        val next = copy(readPath = archivePath, window = nextWindow)
        return DownloadStep.Continue(next, listOf(TerminalRequest.ReadRange(sessionID, archivePath, offset)))
    }

    /**
     * A piece of [readPath] arrived; the caller has written its bytes at [offset] already. The size is checked
     * before the piece is accepted, so a file over the limit is refused without a single request for its data.
     */
    fun onFileRange(path: String, offset: Long, totalBytes: Long, byteCount: Int): DownloadStep {
        if (path != readPath) return DownloadStep.Ignored
        if (totalBytes > TransferLimits.MAXIMUM_DOWNLOAD_BYTES) return DownloadStep.Failed(DownloadFailure.TooLarge)
        val (nextWindow, offsets) = window.received(byteCount, totalBytes)
        val next = copy(window = nextWindow)
        if (nextWindow.isComplete) return DownloadStep.Complete(next)
        if (byteCount == 0 && offsets.isEmpty()) return DownloadStep.Failed(DownloadFailure.ShortRead)
        return DownloadStep.Continue(next, offsets.map { TerminalRequest.ReadRange(sessionID, path, it) })
    }

    /** A failure names the source or the zip; either one ends this download. */
    fun onTransferFailure(path: String, message: String): DownloadStep {
        if (path != readPath && path != sourcePath) return DownloadStep.Ignored
        return DownloadStep.Failed(DownloadFailure.Transfer(message))
    }
}
