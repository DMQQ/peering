package pl.dmq.peering.session.controller

/** How one attempt to hold a control connection ended, as the lifecycle needs to decide what comes next. */
internal sealed interface LinkOutcome {
    /** The route could not be opened or the handshake did not complete. Worth another attempt once linked before. */
    data class Unreachable(val failure: SessionFailure) : LinkOutcome

    /** The host or the relay refused the session. Reconnecting cannot change that. */
    data class Refused(val failure: SessionFailure) : LinkOutcome

    /** The user cancelled a pairing, and the host has been told. */
    data object Cancelled : LinkOutcome

    /** The dial was abandoned because the network moved under it; dial again at once. */
    data object Redial : LinkOutcome

    /** The session was running and ended as [end]. */
    data class Ended(val end: LinkEnd) : LinkOutcome
}
