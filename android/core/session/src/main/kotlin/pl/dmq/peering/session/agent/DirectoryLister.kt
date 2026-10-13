package pl.dmq.peering.session.agent

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.RemoteDirectoryEntry

/** What the computer last said about one folder. [entries] is null while the folder is being asked for or after it failed. */
data class FolderListing(val entries: List<RemoteDirectoryEntry>?, val failure: String?, val loadedAt: Long)

/**
 * Lists folders on the computer for the composer's hints, one at a time because the computer's answers carry no request
 * id: the next directory answer belongs to the folder in flight. Answers are kept for [freshMillis] so typing does not ask
 * again. Call from one thread; the owner feeds the browse events into [onEvent].
 */
class DirectoryLister(
    private val browse: (String) -> Unit,
    private val scope: CoroutineScope,
    private val now: () -> Long,
    private val freshMillis: Long = 60_000,
    private val timeoutMillis: Long = 8_000,
) {
    private val known = MutableStateFlow<Map<String, FolderListing>>(emptyMap())
    private val waiting = ArrayDeque<String>()
    private var inFlight: String? = null
    private var timeout: Job? = null

    val listings: StateFlow<Map<String, FolderListing>> get() = known

    /** Asks for [path] unless a recent answer is kept or the question is already out. */
    fun request(path: String) {
        val kept = known.value[path]
        if (path == inFlight || path in waiting) return
        if (kept != null && now() - kept.loadedAt < freshMillis) return
        waiting.addLast(path)
        pump()
    }

    fun onEvent(event: AgentEvent) {
        when (event) {
            is AgentEvent.Directory -> settle(event.entries, null)
            is AgentEvent.BrowseFailure -> settle(null, event.message)
            else -> Unit
        }
    }

    private fun settle(entries: List<RemoteDirectoryEntry>?, failure: String?) {
        val path = inFlight ?: return
        timeout?.cancel()
        inFlight = null
        known.update { it + (path to FolderListing(entries, failure, now())) }
        pump()
    }

    private fun pump() {
        if (inFlight != null) return
        val next = waiting.removeFirstOrNull() ?: return
        inFlight = next
        browse(next)
        timeout = scope.launch {
            delay(timeoutMillis)
            settle(emptyList(), null)
        }
    }
}
