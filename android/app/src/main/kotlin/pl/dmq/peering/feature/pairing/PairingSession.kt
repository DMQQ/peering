package pl.dmq.peering.feature.pairing

import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.session.controller.CodeCheck

/** One pairing with a computer, as the session layer runs it. The screen reads [phases] and gives digits; it never learns the code. */
interface PairingSession {
    val phases: StateFlow<PairingPhase>

    /** The six digits the user typed. */
    fun submitCode(digits: String): CodeCheck

    /** The code read from the computer's QR code, with the secret it carried when it had one. */
    fun submitScanned(code: String, secret: ByteArray?): CodeCheck

    fun cancel()
}
