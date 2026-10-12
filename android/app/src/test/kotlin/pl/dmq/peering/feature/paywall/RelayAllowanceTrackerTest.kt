package pl.dmq.peering.feature.paywall

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset

class RelayAllowanceTrackerTest {
    private class MemoryUsageStore(var stored: DailyRelayUsage? = null) : RelayUsageStore {
        override fun load(): DailyRelayUsage? = stored

        override fun save(usage: DailyRelayUsage) {
            stored = usage
        }
    }

    private val noon = 1_760_270_400L
    private val day = LocalDate.ofEpochDay(noon / 86_400)

    private fun tracker(
        scope: kotlinx.coroutines.CoroutineScope,
        store: RelayUsageStore = MemoryUsageStore(),
        clock: SettableClock = SettableClock(noon),
        paid: MutableStateFlow<Boolean> = MutableStateFlow(false),
    ) = RelayAllowanceTracker(store, clock, ZoneOffset.UTC, paid, scope)

    @Test
    fun relayTimeAccumulatesAgainstTheFreeDay() = runTest {
        val tracker = tracker(backgroundScope)
        tracker.recordRelaySeconds(600)
        tracker.recordRelaySeconds(60)
        assertEquals(660L, tracker.allowance.value.usedSeconds)
        assertEquals(1140L, tracker.allowance.value.remainingSeconds)
    }

    @Test
    fun sessionTimeOnTheRelayIsRecordedWhileItLasts() = runTest {
        val active = MutableStateFlow(true)
        val tracker = tracker(backgroundScope)
        backgroundScope.launch { tracker.trackSessions(active) }
        advanceTimeBy(25_000)
        active.value = false
        advanceTimeBy(60_000)
        assertEquals(20L, tracker.allowance.value.usedSeconds)
    }

    @Test
    fun theDayRollsOverAtMidnightWithoutAnyNewRecord() = runTest {
        val clock = SettableClock(noon)
        val tracker = tracker(backgroundScope, store = MemoryUsageStore(DailyRelayUsage(day, FREE_DAILY_RELAY_SECONDS)), clock = clock)
        assertTrue(tracker.allowance.value.isSpent)

        clock.unixTime = noon + 13 * 3600
        tracker.refresh()
        assertEquals(0L, tracker.allowance.value.usedSeconds)
        assertFalse(tracker.allowance.value.isSpent)
    }

    @Test
    fun theRecordSurvivesARelaunch() = runTest {
        val store = MemoryUsageStore()
        tracker(backgroundScope, store = store).recordRelaySeconds(120)
        val relaunched = tracker(backgroundScope, store = store)
        assertEquals(120L, relaunched.allowance.value.usedSeconds)
    }

    @Test
    fun aRefusedQuotaSpendsTheDayUntilAPurchaseLiftsTheLimit() = runTest {
        val paid = MutableStateFlow(false)
        val tracker = tracker(backgroundScope, paid = paid)
        tracker.relayRefusedQuota()
        assertTrue(tracker.allowance.value.isSpent)

        paid.value = true
        runCurrent()
        assertFalse(tracker.allowance.value.isSpent)
        assertTrue(tracker.allowance.value.paid)
    }
}
