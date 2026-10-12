package pl.dmq.peering.feature.paywall

import pl.dmq.peering.session.ports.Clock

class SettableClock(var unixTime: Long) : Clock {
    override fun monotonicSeconds(): Double = 0.0

    override fun unixSeconds(): Long = unixTime
}
