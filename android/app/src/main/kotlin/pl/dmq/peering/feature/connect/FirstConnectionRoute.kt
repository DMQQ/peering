package pl.dmq.peering.feature.connect

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import pl.dmq.peering.feature.pairing.PairingActions
import pl.dmq.peering.feature.pairing.PairingCodePresenter
import pl.dmq.peering.feature.pairing.PairingCodeScreen

/** The first-connection column, taking the code and the approval itself once [pairing] is running. */
@Composable
internal fun FirstConnectionRoute(
    state: ConnectUiState,
    actions: ConnectActions,
    pairing: PairingCodePresenter?,
    onSkip: () -> Unit,
    onPairingFinished: () -> Unit,
    onScanCodeRequested: (() -> Unit)?,
    hostName: String?,
    modifier: Modifier = Modifier,
) {
    if (pairing == null) {
        FirstConnectionScreen(state, actions, onSkip, modifier)
        return
    }
    val screen by pairing.state.collectAsState()
    LaunchedEffect(screen) {
        if (screen == PairingCodeScreen.Cancelled) onPairingFinished()
    }
    val pairingActions = remember(pairing, onPairingFinished, onScanCodeRequested) {
        PairingActions(
            onDigitsEntered = { digits -> pairing.submitCode(digits) },
            onCancel = pairing::cancel,
            onFinished = onPairingFinished,
            onScan = onScanCodeRequested,
        )
    }
    BackHandler {
        if (screen is PairingCodeScreen.Failed || screen is PairingCodeScreen.Done) onPairingFinished() else pairing.cancel()
    }
    FirstConnectionScreen(state, actions, onSkip, modifier, screen, pairingActions, hostName)
}
