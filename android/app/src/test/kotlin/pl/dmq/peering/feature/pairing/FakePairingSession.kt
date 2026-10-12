package pl.dmq.peering.feature.pairing

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class FakePairingSession(initial: PairingPhase = PairingPhase.Waiting) : PairingSession {
    private val current = MutableStateFlow(initial)
    override val phases: StateFlow<PairingPhase> = current

    val answers = mutableListOf<Boolean>()
    var cancelCount = 0
        private set

    fun emit(phase: PairingPhase) {
        current.value = phase
    }

    override fun confirm(codesMatch: Boolean) {
        answers += codesMatch
    }

    override fun cancel() {
        cancelCount++
    }
}
