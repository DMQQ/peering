package pl.dmq.peering.session.relay

import pl.dmq.peering.session.ports.Clock

/** Decides when the relay may be asked for presence: at once when nothing was asked yet, then no oftener than [intervalSeconds]. */
class PresenceTicker(
    private val clock: Clock,
    private val intervalSeconds: Double = DEFAULT_INTERVAL_SECONDS,
) {
    private var lastAskedAt: Double? = null

    fun isDue(): Boolean = secondsUntilDue() <= 0.0

    /** Seconds until the next ask may go out, zero when it may go now. */
    fun secondsUntilDue(): Double {
        val asked = lastAskedAt ?: return 0.0
        return (asked + intervalSeconds - clock.monotonicSeconds()).coerceAtLeast(0.0)
    }

    fun markAsked() {
        lastAskedAt = clock.monotonicSeconds()
    }

    companion object {
        const val DEFAULT_INTERVAL_SECONDS = 15.0
    }
}
