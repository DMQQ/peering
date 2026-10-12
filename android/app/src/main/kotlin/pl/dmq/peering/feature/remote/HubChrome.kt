package pl.dmq.peering.feature.remote

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Whether each hub tab is on its list page. The switcher and the close button belong to list pages only; a tab that has
 * pushed a detail page (a chat, a shell, a preview) reports it here and the hub hides them until it comes back.
 */
class HubChrome {
    private var details by mutableStateOf(emptySet<HubTab>())

    fun setAtRoot(tab: HubTab, atRoot: Boolean) {
        details = if (atRoot) details - tab else details + tab
    }

    fun atRoot(tab: HubTab): Boolean = tab !in details

    fun showsSwitcher(selected: HubTab?): Boolean = selected == null || atRoot(selected)
}
