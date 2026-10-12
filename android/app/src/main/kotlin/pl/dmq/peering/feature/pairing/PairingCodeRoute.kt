package pl.dmq.peering.feature.pairing

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier

/** The step where the user types the code the computer shows. Calls [onFinished] once the pairing is done, failed, or cancelled. */
@Composable
fun PairingCodeRoute(
    presenter: PairingCodePresenter,
    onFinished: () -> Unit,
    modifier: Modifier = Modifier,
    onScanRequested: (() -> Unit)?,
    hostName: String? = null,
) {
    val screen by presenter.state.collectAsState()
    LaunchedEffect(screen) {
        if (screen == PairingCodeScreen.Cancelled) onFinished()
    }
    val actions = remember(presenter, onFinished, onScanRequested) {
        PairingActions(
            onDigitsEntered = { digits -> presenter.submitCode(digits) },
            onCancel = presenter::cancel,
            onFinished = onFinished,
            onScan = onScanRequested,
        )
    }
    BackHandler {
        if (screen is PairingCodeScreen.Failed || screen is PairingCodeScreen.Done) onFinished() else presenter.cancel()
    }
    PairingCodeContent(screen = screen, actions = actions, modifier = modifier, hostName = hostName)
}
