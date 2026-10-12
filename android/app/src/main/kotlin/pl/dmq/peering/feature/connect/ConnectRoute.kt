package pl.dmq.peering.feature.connect

import android.content.Intent
import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringAlert

/** The Connect screen. Intents go to [presenter]; the wiring owns the presenter and what connecting and pairing do. */
@Composable
fun ConnectRoute(
    presenter: ConnectPresenter,
    modifier: Modifier = Modifier,
    onScanRequested: (() -> Unit)? = null,
) {
    val state by presenter.state.collectAsState()
    val context = LocalContext.current
    val actions = remember(presenter, onScanRequested, context) {
        ConnectActions(
            onConnect = presenter::connect,
            onPair = presenter::pair,
            onForget = presenter::requestForget,
            onConnectAddress = presenter::connectToAddress,
            onSearchAgain = presenter::searchAgain,
            onOpenWifiSettings = {
                context.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            },
            onEntryTextChanged = presenter.entry::onTextChanged,
            onEntrySubmit = presenter.entry::submit,
            onScan = onScanRequested,
        )
    }
    ConnectScreen(state = state, actions = actions, modifier = modifier)
    if (state.forgetTarget != null) {
        ForgetDialog(onConfirm = presenter::confirmForget, onDismiss = presenter::cancelForget)
    }
}

@Composable
private fun ForgetDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    PeeringAlert(
        title = stringResource(R.string.connect_forget_title),
        message = stringResource(R.string.connect_forget_text),
        confirm = stringResource(R.string.connect_forget_confirm),
        onConfirm = onConfirm,
        cancel = stringResource(R.string.connect_cancel),
        onCancel = onDismiss,
        destructive = true,
    )
}
