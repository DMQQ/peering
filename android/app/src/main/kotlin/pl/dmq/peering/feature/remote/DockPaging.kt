package pl.dmq.peering.feature.remote

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue

/**
 * Which page of the dock is showing. The pager reports where a swipe settled, a dot tap asks for a page, and a change in
 * the pages keeps the same page in view when it still exists and falls back to the first when it does not.
 */
class DockPaging {
    var index by mutableIntStateOf(0)
        private set

    private var ids: List<String> = emptyList()

    fun onPagesChanged(next: List<String>) {
        val shown = ids.getOrNull(index)
        ids = next
        index = if (shown != null && shown in next) next.indexOf(shown) else 0
    }

    /** A swipe came to rest on [page]. */
    fun onSettled(page: Int) {
        if (ids.isNotEmpty()) index = page.coerceIn(0, ids.lastIndex)
    }

    /** A dot was tapped. */
    fun select(page: Int) = onSettled(page)

    fun reset() {
        index = 0
    }
}
