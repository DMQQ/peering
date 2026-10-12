package pl.dmq.peering.feature.pairing

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.session.controller.CodeCheck

/** A session that knows the code [expected] and answers like the controller does, counting wrong tries up to [limit]. */
class FakePairingSession(
    initial: PairingPhase = PairingPhase.EnteringCode(0, null),
    private val expected: String = "042317",
    private val limit: Int = 3,
) : PairingSession {
    private val current = MutableStateFlow(initial)
    override val phases: StateFlow<PairingPhase> = current

    val typed = mutableListOf<String>()
    val secrets = mutableListOf<ByteArray?>()
    var cancelCount = 0
        private set
    private var wrong = 0

    fun emit(phase: PairingPhase) {
        current.value = phase
    }

    override fun submitCode(digits: String): CodeCheck {
        typed += digits
        return check(digits, null)
    }

    override fun submitScanned(code: String, secret: ByteArray?): CodeCheck = check(code, secret)

    private fun check(entry: String, secret: ByteArray?): CodeCheck {
        if (entry == expected) {
            secrets += secret
            current.value = PairingPhase.Waiting
            return CodeCheck.Match
        }
        wrong++
        if (wrong >= limit) return CodeCheck.TooManyAttempts
        current.value = PairingPhase.EnteringCode(wrong, pl.dmq.peering.session.controller.PairingCodeError.WrongCode)
        return CodeCheck.Mismatch
    }

    override fun cancel() {
        cancelCount++
    }
}
