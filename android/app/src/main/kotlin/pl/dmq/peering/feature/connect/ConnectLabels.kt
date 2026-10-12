package pl.dmq.peering.feature.connect

import androidx.annotation.StringRes
import pl.dmq.peering.R

@StringRes
internal fun HostStatus.labelRes(): Int = when (this) {
    HostStatus.Connected -> R.string.connect_status_connected
    HostStatus.Online -> R.string.connect_status_online
    HostStatus.Unknown -> R.string.connect_status_unknown
}

@StringRes
internal fun HostRow.supportingRes(paired: Boolean): Int = when {
    !paired -> R.string.connect_nearby_tap_to_pair
    status == HostStatus.Connected -> R.string.connect_status_connected
    route == HostRoute.Local -> R.string.connect_status_local
    route == HostRoute.Relay -> R.string.connect_status_relay
    else -> status.labelRes()
}

@StringRes
internal fun ConnectMessage.messageRes(): Int = when (this) {
    ConnectMessage.ForgetFailed -> R.string.connect_forget_failed
}
