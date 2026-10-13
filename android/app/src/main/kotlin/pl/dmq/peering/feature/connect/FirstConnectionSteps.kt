package pl.dmq.peering.feature.connect

import pl.dmq.peering.feature.pairing.PairingCodeScreen
import pl.dmq.peering.ui.kit.GuideStepState

/** How the last three steps of the first-connection list read, given where an inline pairing has got to. */
internal data class FirstConnectionSteps(val choose: GuideStepState, val code: GuideStepState, val approve: GuideStepState)

/** [listReady] is true once the first two steps have been ticked and the computers found are shown. */
internal fun firstConnectionSteps(pairing: PairingCodeScreen?, listReady: Boolean): FirstConnectionSteps = when (pairing) {
    null, PairingCodeScreen.Cancelled -> FirstConnectionSteps(
        choose = if (listReady) GuideStepState.Current else GuideStepState.Pending,
        code = GuideStepState.Pending,
        approve = GuideStepState.Pending,
    )
    PairingCodeScreen.Connecting -> FirstConnectionSteps(GuideStepState.Current, GuideStepState.Pending, GuideStepState.Pending)
    is PairingCodeScreen.EnteringCode -> FirstConnectionSteps(GuideStepState.Done, GuideStepState.Current, GuideStepState.Pending)
    PairingCodeScreen.Waiting -> FirstConnectionSteps(GuideStepState.Done, GuideStepState.Done, GuideStepState.Current)
    PairingCodeScreen.Done -> FirstConnectionSteps(GuideStepState.Done, GuideStepState.Done, GuideStepState.Done)
    is PairingCodeScreen.Failed -> FirstConnectionSteps(GuideStepState.Done, GuideStepState.Pending, GuideStepState.Pending)
}
