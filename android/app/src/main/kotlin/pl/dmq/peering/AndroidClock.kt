package pl.dmq.peering

import android.os.SystemClock
import pl.dmq.peering.session.ports.Clock

class AndroidClock : Clock {
    override fun monotonicSeconds(): Double = SystemClock.elapsedRealtimeNanos() / NANOS_PER_SECOND

    override fun unixSeconds(): Long = System.currentTimeMillis() / MILLIS_PER_SECOND

    private companion object {
        const val NANOS_PER_SECOND = 1_000_000_000.0
        const val MILLIS_PER_SECOND = 1_000L
    }
}
