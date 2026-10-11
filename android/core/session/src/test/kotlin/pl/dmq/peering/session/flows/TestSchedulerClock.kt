package pl.dmq.peering.session.flows

import kotlinx.coroutines.test.TestCoroutineScheduler
import pl.dmq.peering.session.ports.Clock

/** Reads the test scheduler's virtual time, so lane timers and fallback windows follow the test's clock. */
class TestSchedulerClock(
    private val scheduler: TestCoroutineScheduler,
    private val unixStart: Long = UNIX_START,
) : Clock {
    override fun monotonicSeconds(): Double = scheduler.currentTime / MILLIS_PER_SECOND

    override fun unixSeconds(): Long = unixStart + (scheduler.currentTime / MILLIS_PER_SECOND).toLong()

    private companion object {
        const val MILLIS_PER_SECOND = 1000.0
        const val UNIX_START = 1_760_000_000L
    }
}
