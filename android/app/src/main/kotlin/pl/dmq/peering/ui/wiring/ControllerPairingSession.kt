package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.feature.pairing.PairingPhase
import pl.dmq.peering.feature.pairing.PairingSession
import pl.dmq.peering.session.controller.CodeCheck
import pl.dmq.peering.session.controller.SessionController

/** The pairing screen over a session that is pairing: its phases come from the session, its answers go back to it. */
internal class ControllerPairingSession(
    private val controller: SessionController,
    scope: CoroutineScope,
) : PairingSession {
    override val phases: StateFlow<PairingPhase> = controller.state
        .map { it.phase.toPairingPhase() }
        .stateIn(scope, SharingStarted.Eagerly, PairingPhase.Waiting)

    override fun submitCode(digits: String): CodeCheck = controller.submitPairingCode(digits)

    override fun submitScanned(code: String, secret: ByteArray?): CodeCheck =
        controller.submitScannedPairingCode(code, secret)

    override fun cancel() {
        controller.disconnect()
    }
}
