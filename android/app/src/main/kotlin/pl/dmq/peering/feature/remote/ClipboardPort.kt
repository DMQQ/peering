package pl.dmq.peering.feature.remote

import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.session.clipboard.ClipboardEntry
import pl.dmq.peering.session.clipboard.ClipboardPush

/** What the Clipboard panel needs from the session beyond plain commands: the history, and pictures, which are not commands. */
interface ClipboardPort {
    /** The clipboards that moved, newest first. */
    val history: StateFlow<List<ClipboardEntry>>

    fun sendImage(png: ByteArray): ClipboardPush

    fun remove(id: Long)

    fun clear()
}
