package pl.dmq.peering.feature.agents

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import pl.dmq.peering.session.ports.KeyValueStore

/** Whether the first-run guide card shows: until it is dismissed once, then only when the help button brings it back. */
class HubGuidePresenter(private val store: KeyValueStore) {
    var visible by mutableStateOf(store.read(KEY) != SEEN)
        private set

    val offersHelp: Boolean get() = !visible

    fun dismiss() {
        visible = false
        store.write(KEY, SEEN)
    }

    fun reopen() {
        visible = true
    }

    private companion object {
        const val KEY = "agents_guide_seen"
        const val SEEN = "1"
    }
}
