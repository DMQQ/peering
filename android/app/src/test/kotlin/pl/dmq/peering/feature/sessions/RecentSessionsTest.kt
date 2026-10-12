package pl.dmq.peering.feature.sessions

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.feature.paywall.RelayAllowance
import pl.dmq.peering.session.history.SessionRecord

class RecentSessionsTest {
    private fun record(path: SessionRecord.Path, startedAt: Long, endedAt: Long?) =
        SessionRecord(id = startedAt, hostId = "h", hostName = "Studio", startedAt = startedAt, endedAt = endedAt, path = path)

    @Test
    fun anOpenSessionRunsUntilNow() {
        assertEquals(30, record(SessionRecord.Path.LAN, 1_000, null).durationSeconds(nowMillis = 31_000))
    }

    @Test
    fun aClosedSessionRunsUntilItEnded() {
        assertEquals(12, record(SessionRecord.Path.LAN, 1_000, 13_000).durationSeconds(nowMillis = 900_000))
    }

    @Test
    fun theSummaryCountsSessionsConnectedTimeAndRelayTime() {
        val records = listOf(
            record(SessionRecord.Path.RELAY, 0, 60_000),
            record(SessionRecord.Path.LAN, 100_000, 130_000),
        )

        assertEquals(RecentSummary(sessionCount = 2, connectedSeconds = 90, relaySeconds = 60), RecentSummary.of(records, nowMillis = 200_000))
    }

    @Test
    fun durationsAreWordedAsTheyAreOnThePhone() {
        assertEquals("45s", durationLabel(45))
        assertEquals("12m 4s", durationLabel(724))
    }

    @Test
    fun theMeterShowsWhatIsLeftAndFlagsAQuarterOrLess() {
        val plenty = RelayMeter.of(RelayAllowance(usedSeconds = 600, paid = false))!!
        val low = RelayMeter.of(RelayAllowance(usedSeconds = 1_400, paid = false))!!

        assertEquals(false, plenty.low)
        assertEquals(true, low.low)
        assertEquals(1_200f / 1_800f, plenty.remainingFraction, 0.0001f)
    }

    @Test
    fun aPaidPlanHasNoMeter() {
        assertNull(RelayMeter.of(RelayAllowance(usedSeconds = 0, paid = true)))
    }
}
