package pl.dmq.peering.feature.pairing

import kotlinx.coroutines.flow.StateFlow

/** One pairing with a Mac, as the session layer runs it. The screen only reads [phases] and answers. */
interface PairingSession {
    val phases: StateFlow<PairingPhase>

    /** The user's answer to the six digits: true when they match the Mac's. */
    fun confirm(codesMatch: Boolean)

    fun cancel()
}
