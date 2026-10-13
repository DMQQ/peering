package pl.dmq.peering.session.controller

import kotlinx.coroutines.CompletableDeferred

/** The six digits the Mac shows and the phone waits to be given, with the user's answer when it comes. */
internal class PairingPrompt(
    private val target: ConnectTarget,
    private val update: ((SessionUiState) -> SessionUiState) -> Unit,
) {
    @Volatile private var pending: PendingCode? = null

    /** Compares [entry] with the displayed code. Read as a mismatch when no code is awaited. */
    fun submit(entry: String, secret: ByteArray?): CodeCheck {
        val awaited = pending ?: return CodeCheck.Mismatch
        val check = awaited.gate.check(entry)
        when (check) {
            CodeCheck.Match -> awaited.answer.complete(PairingDecision(accepted = true, secret = secret))
            CodeCheck.TooManyAttempts -> awaited.answer.complete(PairingDecision(accepted = false, secret = null))
            CodeCheck.Mismatch -> update {
                it.copy(phase = SessionPhase.EnteringPairingCode(awaited.gate.wrongAttempts, PairingCodeError.WrongCode))
            }
        }
        return check
    }

    suspend fun await(code: String): PairingDecision {
        update { it.copy(phase = SessionPhase.EnteringPairingCode(attempts = 0)) }
        val awaited = PendingCode(PairingCodeGate(code), CompletableDeferred())
        pending = awaited
        try {
            val decision = awaited.answer.await()
            update { it.copy(phase = SessionPhase.Connecting(target.path)) }
            return decision
        } finally {
            pending = null
        }
    }

    private class PendingCode(val gate: PairingCodeGate, val answer: CompletableDeferred<PairingDecision>)
}
