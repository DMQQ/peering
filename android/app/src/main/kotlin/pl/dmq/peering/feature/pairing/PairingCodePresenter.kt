package pl.dmq.peering.feature.pairing

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.feature.scan.ScanOutcome
import pl.dmq.peering.session.controller.CodeCheck
import pl.dmq.peering.wire.PairingPayload

class PairingCodePresenter(
    private val session: PairingSession,
    scope: CoroutineScope,
) {
    private val ending = MutableStateFlow(Ending.None)

    val state: StateFlow<PairingCodeScreen> = combine(session.phases, ending) { phase, end ->
        screenFor(phase, end)
    }.stateIn(scope, SharingStarted.Eagerly, PairingCodeScreen.Connecting)

    /** Checks the typed digits. Once a right code was given, or the attempts ran out, later digits are not sent. */
    fun submitCode(digits: String): CodeCheck {
        if (ending.value != Ending.None) return CodeCheck.Mismatch
        return noteOutcome(session.submitCode(digits))
    }

    /** A code read from the computer's screen. The one that matches confirms the pairing with its secret. */
    fun confirmScannedCode(raw: String): ScanOutcome {
        val code = PairingPayload.code(raw) ?: return ScanOutcome.NotAPairingCode
        if (ending.value != Ending.None) return ScanOutcome.WrongCode
        return when (noteOutcome(session.submitScanned(code, PairingPayload.secret(raw)))) {
            CodeCheck.Match -> ScanOutcome.Used
            CodeCheck.Mismatch, CodeCheck.TooManyAttempts -> ScanOutcome.WrongCode
        }
    }

    fun cancel() {
        if (ending.value == Ending.Cancelled) return
        ending.value = Ending.Cancelled
        session.cancel()
    }

    private fun noteOutcome(check: CodeCheck): CodeCheck {
        when (check) {
            CodeCheck.Match -> ending.value = Ending.Answered
            CodeCheck.TooManyAttempts -> ending.value = Ending.TooManyAttempts
            CodeCheck.Mismatch -> Unit
        }
        return check
    }

    private fun screenFor(phase: PairingPhase, end: Ending): PairingCodeScreen = when {
        end == Ending.Cancelled -> PairingCodeScreen.Cancelled
        end == Ending.TooManyAttempts -> PairingCodeScreen.Failed(PairingMessage.TooManyAttempts)
        else -> when (phase) {
            is PairingPhase.EnteringCode ->
                if (end == Ending.Answered) PairingCodeScreen.Waiting else PairingCodeScreen.EnteringCode(phase.attempts, phase.error)
            PairingPhase.Waiting -> if (end == Ending.Answered) PairingCodeScreen.Waiting else PairingCodeScreen.Connecting
            PairingPhase.Done -> PairingCodeScreen.Done
            is PairingPhase.Failed -> PairingCodeScreen.Failed(phase.reason.toPairingMessage())
            is PairingPhase.ConnectionFailed -> PairingCodeScreen.Failed(phase.kind.toPairingMessage(), phase.cause)
        }
    }

    private enum class Ending { None, Answered, TooManyAttempts, Cancelled }
}
