package pl.dmq.peering.session.controller

/** How one control connection ended once it was serving a session. */
sealed interface LinkEnd {
    /** The connection dropped or went silent. The session may be resumed. */
    data object Lost : LinkEnd

    /** The user stopped the session on the Mac. The phone must not reconnect. */
    data object HostStopped : LinkEnd

    /** The session cannot continue and reconnecting would not help. */
    data class Terminal(val failure: SessionFailure) : LinkEnd
}
