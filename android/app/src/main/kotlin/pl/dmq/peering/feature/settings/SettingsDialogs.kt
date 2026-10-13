package pl.dmq.peering.feature.settings

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringAlert

@Composable
internal fun ForgetConfirmDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    PeeringAlert(
        title = stringResource(R.string.settings_forget_title),
        message = stringResource(R.string.settings_forget_text),
        confirm = stringResource(R.string.settings_forget_confirm),
        onConfirm = onConfirm,
        cancel = stringResource(R.string.settings_cancel),
        onCancel = onDismiss,
        destructive = true,
    )
}
