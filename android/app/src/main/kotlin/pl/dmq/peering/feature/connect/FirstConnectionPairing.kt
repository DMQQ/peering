package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.pairing.EnteringCode
import pl.dmq.peering.feature.pairing.PairingActions
import pl.dmq.peering.feature.pairing.PairingCodeScreen
import pl.dmq.peering.ui.kit.GuideStepRow
import pl.dmq.peering.ui.kit.GuideStepState
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.kit.StepDetail
import pl.dmq.peering.ui.theme.PeeringColors

/** Steps three to five while a pairing runs inside the first-connection column. */
@Composable
internal fun PairingSteps(screen: PairingCodeScreen, actions: PairingActions, hostName: String?) {
    val steps = firstConnectionSteps(screen, listReady = true)
    GuideStepRow(3, steps.choose, stringResource(R.string.first_step_choose), Modifier) {
        if (screen is PairingCodeScreen.Connecting) {
            StepDetail(stringResource(R.string.pairing_step_connecting_detail))
            PeeringSpinner(color = PeeringColors.ink)
        } else {
            StepDetail(hostName?.let { stringResource(R.string.pairing_step_found_detail_named, it) } ?: stringResource(R.string.pairing_step_found_detail))
        }
    }
    GuideStepRow(4, steps.code, stringResource(R.string.pairing_step_code), Modifier) {
        when {
            screen is PairingCodeScreen.EnteringCode -> EnteringCode(screen, actions, hostName)
            steps.code == GuideStepState.Done -> StepDetail(stringResource(R.string.pairing_step_code_done))
        }
    }
    GuideStepRow(5, steps.approve, stringResource(R.string.pairing_step_approve), Modifier, isLast = true) {
        when (screen) {
            PairingCodeScreen.Waiting -> {
                StepDetail(hostName?.let { stringResource(R.string.pairing_code_waiting_named, it) } ?: stringResource(R.string.pairing_code_waiting))
                PeeringSpinner(color = PeeringColors.ink)
            }
            PairingCodeScreen.Done -> {
                StepDetail(stringResource(R.string.pairing_code_done))
                PrimaryButton(stringResource(R.string.pairing_code_back), actions.onFinished, Modifier.padding(top = 8.dp))
            }
            else -> Unit
        }
    }
}
