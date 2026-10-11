package pl.dmq.peering.session.connection

/**
 * The pings still waiting for an answer. A pong is matched by its sequence, and every older ping is dropped with it,
 * so a lost ping can never be read as a very fast one.
 */
internal class PingLedger {
    internal class Ping(val sequence: Long, val sentAtSeconds: Double)

    private val inFlight = ArrayDeque<Ping>()
    private var nextSequence = 0L

    fun record(nowSeconds: Double): Ping {
        nextSequence += 1
        val ping = Ping(nextSequence, nowSeconds)
        inFlight.addLast(ping)
        if (inFlight.size > IN_FLIGHT_LIMIT) inFlight.removeFirst()
        return ping
    }

    /** A null [sequence] is an empty pong from a host that does not echo the payload, read as the oldest open ping. */
    fun answered(sequence: Long?): Ping? {
        if (inFlight.isEmpty()) return null
        val index = if (sequence == null) 0 else inFlight.indexOfFirst { it.sequence == sequence }
        if (index < 0) return null
        val ping = inFlight[index]
        repeat(index + 1) { inFlight.removeFirst() }
        return ping
    }

    private companion object {
        /** Four pings is four seconds at the one-second cadence: past that the link has stopped answering. */
        const val IN_FLIGHT_LIMIT = 4
    }
}
