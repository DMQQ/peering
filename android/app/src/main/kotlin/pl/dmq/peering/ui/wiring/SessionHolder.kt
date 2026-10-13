package pl.dmq.peering.ui.wiring

import pl.dmq.peering.DebugLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import pl.dmq.peering.session.controller.ConnectTarget
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.hosts.HostDirectory
import pl.dmq.peering.session.hosts.HostMacAddresses

/**
 * The one session the app shows. Starting another ends the current one first. Each Mac is remembered under the name it
 * gives itself when a session to it becomes ready. A dialled address with no known device ID is not remembered.
 */
internal class SessionHolder(
    private val factory: SessionOpener,
    private val directory: HostDirectory,
    private val scope: CoroutineScope,
    private val macAddresses: HostMacAddresses? = null,
) {
    private val current = MutableStateFlow<ActiveSession?>(null)
    private var naming: Job? = null
    private var failures: Job? = null

    val active: StateFlow<ActiveSession?> = current.asStateFlow()

    fun connect(target: ConnectTarget): ActiveSession {
        current.value?.close()
        naming?.cancel()
        failures?.cancel()
        val session = factory.open(target, scope)
        current.value = session
        naming = scope.launch {
            session.controller.state
                .map { it.phase }
                .filterIsInstance<SessionPhase.Ready>()
                .distinctUntilChanged()
                .collect { ready ->
                    DebugLog.d(TAG) { "session ready on ${ready.path}" }
                    target.hostId?.let {
                        directory.remember(it, ready.hostName, ready.path)
                        macAddresses?.remember(it, ready.macAddresses)
                    }
                }
        }
        failures = scope.launch {
            session.controller.state
                .map { it.phase }
                .filterIsInstance<SessionPhase.Failed>()
                .distinctUntilChanged()
                .collect { failed -> DebugLog.w(TAG, { "session failed: ${failed.reason.javaClass.simpleName}" }) }
        }
        session.controller.connect()
        return session
    }

    fun end() {
        DebugLog.d(TAG) { "session ended by the user" }
        current.value?.close()
        naming?.cancel()
        naming = null
        failures?.cancel()
        failures = null
        current.value = null
    }

    private companion object {
        const val TAG = "PeeringSession"
    }
}
