package pl.dmq.peering.background

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringAlert

/** The sentence shown once, before the system asks for the notification permission. */
@Composable
internal fun NotificationExplanation(permission: NotificationPermission) {
    val shown by permission.explanationShown.collectAsState()
    if (!shown) return
    PeeringAlert(
        title = stringResource(R.string.bg_rationale_title),
        message = stringResource(R.string.bg_rationale_message),
        confirm = stringResource(R.string.bg_rationale_allow),
        onConfirm = permission::onExplanationAccepted,
        cancel = stringResource(R.string.bg_rationale_later),
        onCancel = permission::onExplanationDeclined,
    )
}
