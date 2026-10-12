package pl.dmq.peering.ui.wiring

import androidx.annotation.StringRes
import pl.dmq.peering.R
import pl.dmq.peering.session.controller.ConnectFailureKind
import pl.dmq.peering.session.controller.SessionFailure

@StringRes
internal fun SessionFailure.messageRes(): Int = when (this) {
    is SessionFailure.Handshake -> R.string.session_failed_handshake
    SessionFailure.Quota -> R.string.session_failed_quota
    SessionFailure.VersionMismatch -> R.string.session_failed_version
    is SessionFailure.HostOffline -> R.string.session_failed_offline
    is SessionFailure.RelayRefused -> R.string.session_failed_relay
    is SessionFailure.ConnectionFailed -> kind.messageRes()
    SessionFailure.HostNotFound -> R.string.session_failed_not_found
    SessionFailure.MalformedFrame -> R.string.session_failed_malformed
    SessionFailure.ConnectionLost -> R.string.session_failed_lost
}

@StringRes
internal fun ConnectFailureKind.messageRes(): Int = when (this) {
    ConnectFailureKind.Unreachable -> R.string.session_failed_unreachable
    ConnectFailureKind.Refused -> R.string.session_failed_refused
    ConnectFailureKind.TlsFailed -> R.string.session_failed_tls
    ConnectFailureKind.Timeout -> R.string.session_failed_timeout
}
