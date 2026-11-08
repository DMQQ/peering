package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import pl.dmq.peering.session.controller.SessionPhase

/**
 * Holds the low-latency Wi-Fi lock for as long as a session is being set up, served or recovered, and lets go once there
 * is none, so the radio is only kept awake while someone is using the connection.
 */
internal class WifiLatencyKeeper(
    private val phases: Flow<SessionPhase?>,
    private val acquire: () -> Unit,
    private val release: () -> Unit,
) {
    fun start(scope: CoroutineScope): Job = scope.launch {
        phases.map(::wanted).distinctUntilChanged().collect { if (it) acquire() else release() }
    }

    private fun wanted(phase: SessionPhase?): Boolean =
        phase is SessionPhase.Connecting || phase is SessionPhase.Ready || phase is SessionPhase.Reconnecting
}
