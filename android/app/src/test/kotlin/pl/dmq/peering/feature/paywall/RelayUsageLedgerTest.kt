package pl.dmq.peering.feature.paywall

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate

class RelayUsageLedgerTest {
    private val today = LocalDate.of(2026, 10, 12)
    private val yesterday = today.minusDays(1)

    @Test
    fun aDayWithNoRecordHasNothingUsed() {
        assertEquals(0L, RelayUsageLedger.usedOn(null, today))
    }

    @Test
    fun usageAccumulatesWithinTheSameDay() {
        val first = RelayUsageLedger.added(null, today, 600)
        val second = RelayUsageLedger.added(first, today, 90)
        assertEquals(690L, second.seconds)
        assertEquals(690L, RelayUsageLedger.usedOn(second, today))
    }

    @Test
    fun aNewDayStartsFromNothing() {
        val yesterdayUse = DailyRelayUsage(yesterday, 1500)
        assertEquals(0L, RelayUsageLedger.usedOn(yesterdayUse, today))
        assertEquals(30L, RelayUsageLedger.added(yesterdayUse, today, 30).seconds)
    }

    @Test
    fun aRefusedQuotaTakesTheWholeDay() {
        val spent = RelayUsageLedger.spent(today)
        assertEquals(FREE_DAILY_RELAY_SECONDS, RelayUsageLedger.usedOn(spent, today))
    }

    @Test
    fun theRelaysRemainingTimeBecomesTheUseOfTheDay() {
        assertEquals(97L, RelayUsageLedger.fromRemaining(today, 1703).seconds)
        assertEquals(0L, RelayUsageLedger.fromRemaining(today, 5000).seconds)
        assertEquals(FREE_DAILY_RELAY_SECONDS, RelayUsageLedger.fromRemaining(today, 0).seconds)
    }
}
