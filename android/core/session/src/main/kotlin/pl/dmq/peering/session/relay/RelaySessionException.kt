package pl.dmq.peering.session.relay

/** Why the relay did not give a session. Each case is something the user can act on or read. */
sealed class RelaySessionException(message: String) : Exception(message) {
    data object QuotaExceeded : RelaySessionException("The relay's free time is used up for today.")

    data object VersionMismatch :
        RelaySessionException("The relay and this app speak different protocol versions.")

    class HostOffline(val hostId: String) : RelaySessionException("The computer $hostId is not registered with the relay.")

    class Refused(val code: String, val detail: String) :
        RelaySessionException("The relay refused the session ($code): $detail")

    class UnexpectedReply(val type: String) : RelaySessionException("The relay answered out of order with $type.")
}
