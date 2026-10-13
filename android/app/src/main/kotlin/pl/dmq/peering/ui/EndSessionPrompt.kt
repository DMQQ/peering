package pl.dmq.peering.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringAlert

/** Asked before a link from outside the app ends the live session, because any page or app can send one. */
@Composable
internal fun EndSessionPrompt(onConfirm: () -> Unit, onCancel: () -> Unit) {
    PeeringAlert(
        title = stringResource(R.string.link_end_title),
        message = stringResource(R.string.link_end_message),
        confirm = stringResource(R.string.link_end_confirm),
        onConfirm = onConfirm,
        cancel = stringResource(R.string.connect_cancel),
        onCancel = onCancel,
        destructive = true,
    )
}
