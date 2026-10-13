package pl.dmq.peering.feature.connect

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R

@StringRes
internal fun HostStatus.labelRes(): Int = when (this) {
    HostStatus.Connected -> R.string.connect_status_connected
    HostStatus.Online -> R.string.connect_status_online
    HostStatus.Unknown -> R.string.connect_status_unknown
}

@StringRes
internal fun HostRow.pairedDetailRes(): Int = when {
    status == HostStatus.Connected -> R.string.connect_status_connected
    route == HostRoute.Local -> R.string.connect_status_local
    route == HostRoute.Relay -> R.string.connect_status_relay
    else -> status.labelRes()
}

@Composable
internal fun ConnectMessage.text(): String = when (this) {
    ConnectMessage.ForgetFailed -> stringResource(R.string.connect_forget_failed)
    ConnectMessage.WakeNoAddress -> stringResource(R.string.connect_wake_no_address)
    ConnectMessage.WakeUnreadable -> stringResource(R.string.connect_wake_unreadable)
    is ConnectMessage.WakeSent -> pluralStringResource(R.plurals.connect_wake_sent, count, count)
}
