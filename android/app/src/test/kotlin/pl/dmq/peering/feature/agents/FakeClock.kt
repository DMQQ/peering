package pl.dmq.peering.feature.agents

import pl.dmq.peering.session.ports.Clock

class FakeClock(var unix: Long = 1_000_000L) : Clock {
    override fun monotonicSeconds(): Double = unix.toDouble()

    override fun unixSeconds(): Long = unix
}
