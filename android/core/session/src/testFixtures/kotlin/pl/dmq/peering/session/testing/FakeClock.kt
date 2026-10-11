package pl.dmq.peering.session.testing

import pl.dmq.peering.session.ports.Clock

/** A clock that moves only when a test says so. */
class FakeClock(private var monotonic: Double = 0.0, var unixNow: Long = 0L) : Clock {
    override fun monotonicSeconds(): Double = monotonic

    override fun unixSeconds(): Long = unixNow

    fun advance(seconds: Double) {
        monotonic += seconds
    }
}
