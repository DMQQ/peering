package pl.dmq.peering.feature.agents

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Where the folders a phone has started chats in are kept, per Mac. */
interface FolderRecentsStore {
    fun load(hostID: String): List<String>

    fun save(hostID: String, paths: List<String>)
}

/**
 * The folders chats were started in on one Mac, most recent first. [paths] is what the picker offers as shortcuts.
 */
class FolderRecents(
    private val store: FolderRecentsStore,
    private val hostID: String,
    private val limit: Int = LIMIT,
) {
    private val mutablePaths = MutableStateFlow(store.load(hostID).take(limit))

    val paths: StateFlow<List<String>> = mutablePaths.asStateFlow()

    fun record(path: String) {
        val next = recorded(mutablePaths.value, path, limit)
        if (next == mutablePaths.value) return
        mutablePaths.value = next
        store.save(hostID, next)
    }

    companion object {
        const val LIMIT = 6

        /** [path] moves to the front, the others keep their order, and the list keeps at most [limit] folders. */
        fun recorded(paths: List<String>, path: String, limit: Int): List<String> {
            if (path.isBlank()) return paths.take(limit)
            return (listOf(path) + paths.filterNot { it == path }).take(limit)
        }
    }
}
