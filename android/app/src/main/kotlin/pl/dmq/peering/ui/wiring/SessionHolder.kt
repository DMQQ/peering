package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.session.controller.ConnectTarget

/** The one session the app shows. Starting another ends the current one first. */
internal class SessionHolder(private val factory: SessionPortsFactory, private val scope: CoroutineScope) {
    private val current = MutableStateFlow<ActiveSession?>(null)

    val active: StateFlow<ActiveSession?> = current.asStateFlow()

    fun connect(target: ConnectTarget): ActiveSession {
        current.value?.close()
        val session = factory.open(target, scope)
        current.value = session
        session.controller.connect()
        return session
    }

    fun end() {
        current.value?.close()
        current.value = null
    }
}
