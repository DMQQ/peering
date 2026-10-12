package pl.dmq.peering.feature.pairing

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.feature.scan.ScanOutcome
import pl.dmq.peering.feature.scan.pairingCodeScanOutcome
import pl.dmq.peering.wire.PairingPayload

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

    /** A code read from the Mac's screen. The one that matches the digits on this screen confirms the pairing with its secret. */
    fun confirmScannedCode(raw: String): ScanOutcome {
        val expected = (state.value as? PairingCodeScreen.Comparing)?.code ?: return ScanOutcome.WrongCode
        val outcome = pairingCodeScanOutcome(raw, expected)
        if (outcome != ScanOutcome.Used || answered.value || cancelled.value) return outcome
        answered.value = true
        session.confirm(codesMatch = true, secret = PairingPayload.secret(raw))
        return outcome
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
