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
internal fun ConnectMessage.messageRes(): Int = when (this) {
    ConnectMessage.ForgetFailed -> R.string.connect_forget_failed
}
