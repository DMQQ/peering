package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AgentUsage
import pl.dmq.peering.wire.AgentUsageLimit

class UsageSummaryTest {
    private fun usage(
        used: Long? = null,
        window: Long? = null,
        limits: List<AgentUsageLimit> = emptyList(),
        cached: Long = 0,
    ) = AgentUsage(
        contextUsedTokens = used,
        contextWindowTokens = window,
        inputTokens = 10,
        cachedTokens = cached,
        outputTokens = 20,
        limits = limits,
    )

    @Test
    fun tokensReadCompactly() {
        assertEquals("999", ContextMeter.tokens(999))
        assertEquals("70k", ContextMeter.tokens(70_000))
        assertEquals("200k", ContextMeter.tokens(200_000))
        assertEquals("1M", ContextMeter.tokens(1_000_000))
        assertEquals("1.2M", ContextMeter.tokens(1_200_000))
    }

    @Test
    fun theFractionNeedsBothNumbers() {
        assertNull(ContextMeter.fraction(100, null))
        assertNull(ContextMeter.fraction(null, 200))
        assertNull(ContextMeter.fraction(100, 0))
        assertEquals(0.5, ContextMeter.fraction(100, 200)!!, 0.0)
        assertEquals(1.0, ContextMeter.fraction(500, 200)!!, 0.0)
    }

    @Test
    fun theChipShowsOnlyWhatTheCliReported() {
        assertNull(ContextChip.of(null))
        assertNull(ContextChip.of(usage(used = 5)))
        val withContext = ContextChip.of(usage(used = 70_000, window = 200_000))!!
        assertEquals("70k / 200k", withContext.contextLabel)
        assertNull(withContext.fiveHourPercent)
        val withLimit = ContextChip.of(usage(limits = listOf(AgentUsageLimit("5 hours", 0.42))))!!
        assertNull(withLimit.contextLabel)
        assertEquals(42, withLimit.fiveHourPercent)
    }

    @Test
    fun theChipWarnsWhenContextOrTheFiveHourWindowIsNearlyFull() {
        assertFalse(ContextChip.of(usage(used = 100, window = 200))!!.nearlyFull)
        assertTrue(ContextChip.of(usage(used = 170, window = 200))!!.nearlyFull)
        assertTrue(ContextChip.of(usage(limits = listOf(AgentUsageLimit("5 hours", 0.9))))!!.nearlyFull)
    }

    @Test
    fun theSheetHidesAZeroCacheAndConvertsResetTimes() {
        val ui = UsageUi.of(usage(limits = listOf(AgentUsageLimit("Week", 0.25, resetsAt = 10.0))))
        assertNull(ui.cachedTokens)
        assertEquals(0.75, ui.limits.single().leftFraction, 0.0)
        assertEquals(978_307_210L, ui.limits.single().resetsAtUnix)
        assertEquals(5L, UsageUi.of(usage(cached = 5)).cachedTokens)
    }

    @Test
    fun noUsageIsAnEmptySheetNotZeros() {
        val ui = UsageUi.of(null)
        assertNull(ui.inputTokens)
        assertNull(ui.contextFraction)
        assertTrue(ui.limits.isEmpty())
    }
}
