package pl.dmq.peering.feature.files

import pl.dmq.peering.DebugLog
import java.util.TreeMap

/**
 * Puts the pieces of one download into its [sink] in offset order. Pieces that arrive early wait until the bytes before
 * them are written, and a piece already written is ignored. A destination failure, or a cancel, discards the sink once
 * and ends the download; every later call is then a no-op.
 */
class DownloadCoordinator(private val sink: DownloadSink) {
    private val waiting = TreeMap<Long, ByteArray>()

    var writtenBytes: Long = 0
        private set

    var outcome: DownloadOutcome? = null
        private set

    fun accept(offset: Long, bytes: ByteArray) {
        if (outcome != null || offset < writtenBytes) return
        waiting[offset] = bytes
        flush()
    }

    /** Commits the file once every piece before the end is written. A download with a gap is not complete. */
    fun complete() {
        if (outcome != null) return
        if (waiting.isNotEmpty()) return fail(DownloadOutcome.Failed.INCOMPLETE)
        try {
            sink.commit()
            outcome = DownloadOutcome.Committed
        } catch (failure: Exception) {
            fail(DownloadOutcome.Failed(failure.message.orEmpty()))
        }
    }

    fun cancel() {
        if (outcome != null) return
        discardSink()
        outcome = DownloadOutcome.Discarded
    }

    private fun flush() {
        while (true) {
            val next = waiting.remove(writtenBytes) ?: return
            try {
                sink.write(next)
            } catch (failure: Exception) {
                return fail(DownloadOutcome.Failed(failure.message.orEmpty()))
            }
            writtenBytes += next.size
        }
    }

    private fun fail(reason: DownloadOutcome.Failed) {
        discardSink()
        outcome = reason
    }

    /** A provider can throw anything (a revoked grant, a dead process); the download has ended either way. */
    private fun discardSink() {
        try {
            sink.discard()
        } catch (failure: Exception) {
            DebugLog.w(TAG, { "discarding the download failed" }, failure)
        }
    }
}

sealed interface DownloadOutcome {
    data object Committed : DownloadOutcome

    data object Discarded : DownloadOutcome

    data class Failed(val message: String) : DownloadOutcome {
        companion object {
            val INCOMPLETE = Failed("incomplete")
        }
    }
}

private const val TAG = "PeeringDownload"
