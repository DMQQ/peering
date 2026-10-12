package pl.dmq.peering.feature.remote

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import pl.dmq.peering.session.ports.KeyValueStore

/**
 * Which tab of the hub panel is showing. The panel opens on the tab used last when the computer still offers it, else on
 * the first it offers; picking a tab is remembered for the next time.
 */
class HubTabsPresenter(
    val offered: List<HubTab>,
    private val store: KeyValueStore,
) {
    var selected by mutableStateOf(initial())
        private set

    fun select(tab: HubTab) {
        if (tab !in offered) return
        selected = tab
        store.write(KEY, tab.name)
    }

    private fun initial(): HubTab? {
        val last = store.read(KEY)?.let { name -> HubTab.entries.firstOrNull { it.name == name } }
        return last?.takeIf { it in offered } ?: offered.firstOrNull()
    }

    private companion object {
        const val KEY = "hub_tab"
    }
}
