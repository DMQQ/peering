package pl.dmq.peering.ui.wiring

import androidx.annotation.StringRes
import pl.dmq.peering.R
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.controller.ConnectFailureKind
import pl.dmq.peering.session.controller.SessionFailure

@StringRes
internal fun SessionFailure.messageRes(): Int = when (this) {
    is SessionFailure.Handshake -> reason.messageRes()
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
    ConnectFailureKind.Closed -> R.string.session_failed_closed
}

/** A changed key is the one handshake failure the person must act on, so it is told apart from the rest. */
@StringRes
internal fun FailureReason.messageRes(): Int = when (this) {
    is FailureReason.PinMismatch -> R.string.session_failed_key_changed
    is FailureReason.HostIdMismatch -> R.string.session_failed_wrong_computer
    is FailureReason.NoPinOnFile -> R.string.session_failed_no_pin
    else -> R.string.session_failed_handshake
}
