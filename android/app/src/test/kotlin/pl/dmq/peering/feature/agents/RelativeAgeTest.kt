package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Test

class RelativeAgeTest {
    @Test
    fun underAMinuteIsJustNow() {
        assertEquals(RelativeAge.JustNow, RelativeAge.between(nowUnix = 1_059, thenUnix = 1_000))
    }

    @Test
    fun aFutureTimestampIsJustNowRatherThanNegative() {
        assertEquals(RelativeAge.JustNow, RelativeAge.between(nowUnix = 1_000, thenUnix = 2_000))
    }

    @Test
    fun minutesRoundDownAndStayInTheMinuteUnit() {
        assertEquals(RelativeAge.Minutes(1), RelativeAge.between(nowUnix = 1_060, thenUnix = 1_000))
        assertEquals(RelativeAge.Minutes(59), RelativeAge.between(nowUnix = 4_599, thenUnix = 1_000))
    }

    @Test
    fun hoursAndDaysUseTheirOwnUnit() {
        assertEquals(RelativeAge.Hours(1), RelativeAge.between(nowUnix = 4_600, thenUnix = 1_000))
        assertEquals(RelativeAge.Days(1), RelativeAge.between(nowUnix = 1_000 + 86_400, thenUnix = 1_000))
        assertEquals(RelativeAge.Days(3), RelativeAge.between(nowUnix = 1_000 + 3 * 86_400 + 5, thenUnix = 1_000))
    }
}
