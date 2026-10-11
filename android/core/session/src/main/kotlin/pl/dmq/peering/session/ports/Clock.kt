package pl.dmq.peering.session.ports

/** Time as the session layer reads it. Waiting is done with coroutine delays, not through this port. */
interface Clock {
    /** Seconds from a clock that never goes backwards, for measuring intervals. */
    fun monotonicSeconds(): Double

    /** Whole seconds since the Unix epoch, for values a peer checks against its own time. */
    fun unixSeconds(): Long
}
