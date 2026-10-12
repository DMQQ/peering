package pl.dmq.peering.ui.wiring

import androidx.annotation.StringRes
import pl.dmq.peering.R
import pl.dmq.peering.session.controller.SessionFailure

@StringRes
internal fun SessionFailure.messageRes(): Int = when (this) {
    is SessionFailure.Handshake -> R.string.session_failed_handshake
    SessionFailure.Quota -> R.string.session_failed_quota
    SessionFailure.VersionMismatch -> R.string.session_failed_version
    is SessionFailure.HostOffline -> R.string.session_failed_offline
    is SessionFailure.RelayRefused -> R.string.session_failed_relay
    SessionFailure.Unreachable -> R.string.session_failed_unreachable
    SessionFailure.HostNotFound -> R.string.session_failed_not_found
    SessionFailure.MalformedFrame -> R.string.session_failed_malformed
    SessionFailure.ConnectionLost -> R.string.session_failed_lost
}
