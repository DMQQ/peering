package pl.dmq.peering.feature.pairing

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn

class PairingCodePresenter(
    private val session: PairingSession,
    scope: CoroutineScope,
) {
    private val answered = MutableStateFlow(false)
    private val cancelled = MutableStateFlow(false)

    val state: StateFlow<PairingCodeScreen> = combine(session.phases, answered, cancelled) { phase, given, stopped ->
        screenFor(phase, given, stopped)
    }.stateIn(scope, SharingStarted.Eagerly, PairingCodeScreen.Waiting)

    fun confirm(codesMatch: Boolean) {
        if (answered.value || cancelled.value) return
        answered.value = true
        session.confirm(codesMatch)
    }

    fun cancel() {
        if (cancelled.value) return
        cancelled.value = true
        session.cancel()
    }

    private fun screenFor(phase: PairingPhase, given: Boolean, stopped: Boolean): PairingCodeScreen = when {
        stopped -> PairingCodeScreen.Cancelled
        else -> when (phase) {
            is PairingPhase.Confirming -> if (given) PairingCodeScreen.Waiting else PairingCodeScreen.Comparing(phase.code)
            PairingPhase.Waiting -> PairingCodeScreen.Waiting
            PairingPhase.Done -> PairingCodeScreen.Done
            is PairingPhase.Failed -> PairingCodeScreen.Failed(phase.reason.toPairingMessage())
        }
    }
}
