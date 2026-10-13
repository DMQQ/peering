package pl.dmq.peering.feature.agents

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import pl.dmq.peering.session.ports.KeyValueStore

/** Whether the first-run guide card shows: until it is dismissed once, then only when the help button brings it back. */
class HubGuidePresenter(private val store: KeyValueStore, private val key: String = KEY) {
    var visible by mutableStateOf(store.read(key) != SEEN)
        private set

    val offersHelp: Boolean get() = !visible

    fun dismiss() {
        visible = false
        store.write(key, SEEN)
    }

    fun reopen() {
        visible = true
    }

    companion object {
        private const val KEY = "agents_guide_seen"
        const val TERMINALS_KEY = "terminals_guide_seen"
        private const val SEEN = "1"
    }
}
