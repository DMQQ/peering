package pl.dmq.peering.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringAlert
import pl.dmq.peering.widget.WidgetLink

/** Asked before a link from outside the app connects, pairs or disconnects, because any page or app can send one. */
@Composable
internal fun OutsideLinkPrompt(link: WidgetLink, onConfirm: () -> Unit, onCancel: () -> Unit) {
    if (link is WidgetLink.Disconnect) return EndSessionPrompt(onConfirm, onCancel)
    PeeringAlert(
        title = stringResource(R.string.link_open_title),
        message = stringResource(if (link is WidgetLink.Device) R.string.link_pair_message else R.string.link_open_message),
        confirm = stringResource(R.string.link_open_confirm),
        onConfirm = onConfirm,
        cancel = stringResource(R.string.connect_cancel),
        onCancel = onCancel,
    )
}
