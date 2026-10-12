package pl.dmq.peering.session.controller

import pl.dmq.peering.session.connection.FailureReason

/** Why a session could not start or stopped for good, in terms the user can act on. */
sealed interface SessionFailure {
    /** Whether trying again can succeed. A refused pin or a protocol mismatch will not change by itself. */
    val canRetry: Boolean

    /** The handshake was refused, or the host's answer did not fit this phone. */
    data class Handshake(val reason: FailureReason) : SessionFailure {
        override val canRetry: Boolean
            get() = reason !is FailureReason.ProtocolMismatch &&
                reason !is FailureReason.PinMismatch &&
                reason !is FailureReason.NoPinOnFile &&
                reason !is FailureReason.HostIdMismatch
    }

    /** The relay's free time for today is used up. */
    data object Quota : SessionFailure {
        override val canRetry: Boolean get() = false
    }

    /** The relay speaks another protocol version than this app. */
    data object VersionMismatch : SessionFailure {
        override val canRetry: Boolean get() = false
    }

    /** The relay has no registration for the Mac. The Mac may come back, so the phone may try again. */
    data class HostOffline(val hostId: String) : SessionFailure {
        override val canRetry: Boolean get() = true
    }

    /** The relay refused the session for another reason. */
    data class RelayRefused(val code: String, val detail: String) : SessionFailure {
        override val canRetry: Boolean get() = false
    }

    /** The host could not be reached on the network, or did not complete the handshake in time. */
    data object Unreachable : SessionFailure {
        override val canRetry: Boolean get() = true
    }

    /** Pairing could not find the host on the local network. */
    data object HostNotFound : SessionFailure {
        override val canRetry: Boolean get() = true
    }

    /** The host sent bytes that are not a frame this phone can read, so the stream cannot be trusted any further. */
    data object MalformedFrame : SessionFailure {
        override val canRetry: Boolean get() = true
    }

    /** Reconnecting used every step of the ladder without a handshake that completed. */
    data object ConnectionLost : SessionFailure {
        override val canRetry: Boolean get() = true
    }
}
