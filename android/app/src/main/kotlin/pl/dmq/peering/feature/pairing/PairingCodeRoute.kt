package pl.dmq.peering.feature.pairing

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier

/** The code comparison step. Calls [onFinished] once the pairing is done, failed, or cancelled. */
@Composable
fun PairingCodeRoute(
    presenter: PairingCodePresenter,
    onFinished: () -> Unit,
    modifier: Modifier = Modifier,
    onScanRequested: (() -> Unit)? = null,
) {
    val screen by presenter.state.collectAsState()
    LaunchedEffect(screen) {
        if (screen == PairingCodeScreen.Cancelled) onFinished()
    }
    val actions = remember(presenter, onFinished, onScanRequested) {
        PairingActions(
            onMatch = { presenter.confirm(codesMatch = true) },
            onMismatch = { presenter.confirm(codesMatch = false) },
            onCancel = presenter::cancel,
            onFinished = onFinished,
            onScan = onScanRequested,
        )
    }
    PairingCodeContent(screen = screen, actions = actions, modifier = modifier)
}
