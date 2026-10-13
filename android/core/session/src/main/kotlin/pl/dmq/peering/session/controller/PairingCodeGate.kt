package pl.dmq.peering.session.controller

import java.security.MessageDigest

/** Checks digits typed or scanned by the user against the code the handshake derived. The code never leaves this class. */
internal class PairingCodeGate(private val expected: String, private val limit: Int = MAX_PAIRING_ATTEMPTS) {
    var wrongAttempts = 0
        private set

    fun check(digits: String): CodeCheck {
        if (MessageDigest.isEqual(digits.toByteArray(), expected.toByteArray())) return CodeCheck.Match
        wrongAttempts++
        return if (wrongAttempts >= limit) CodeCheck.TooManyAttempts else CodeCheck.Mismatch
    }

    override fun toString(): String = "PairingCodeGate(wrongAttempts=$wrongAttempts)"
}
