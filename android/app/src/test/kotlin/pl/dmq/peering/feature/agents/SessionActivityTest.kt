package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.agent.TranscriptState
import pl.dmq.peering.wire.AgentSessionInfo
import pl.dmq.peering.wire.AgentSessionState

class SessionActivityTest {
    private fun session(createdAt: Double, lastIndex: Long, transcriptIndex: Long = 0) = AgentChatSession(
        info = AgentSessionInfo(
            id = "S1", agentID = "claude", title = "t", directory = "/d",
            state = AgentSessionState.IDLE, lastIndex = lastIndex, createdAt = createdAt,
        ),
        transcript = TranscriptState(lastIndex = transcriptIndex),
    )

    @Test
    fun firstSeenChatIsDatedFromItsCreationOnTheMac() {
        val clock = FakeClock(unix = 5_000)
        val activity = SessionActivity(clock)
        assertEquals(978_307_200L + 100, activity.lastActivityUnix(session(createdAt = 100.0, lastIndex = 0)))
    }

    @Test
    fun activityMovesToNowWhenTheEventIndexAdvances() {
        val clock = FakeClock(unix = 5_000)
        val activity = SessionActivity(clock)
        activity.lastActivityUnix(session(createdAt = 100.0, lastIndex = 3))
        clock.unix = 6_000
        assertEquals(6_000L, activity.lastActivityUnix(session(createdAt = 100.0, lastIndex = 4)))
    }

    @Test
    fun unchangedIndexKeepsTheEarlierActivity() {
        val clock = FakeClock(unix = 5_000)
        val activity = SessionActivity(clock)
        activity.lastActivityUnix(session(createdAt = 100.0, lastIndex = 3))
        clock.unix = 9_000
        assertEquals(978_307_200L + 100, activity.lastActivityUnix(session(createdAt = 100.0, lastIndex = 3)))
    }

    @Test
    fun transcriptIndexCountsAsActivityToo() {
        val clock = FakeClock(unix = 5_000)
        val activity = SessionActivity(clock)
        activity.lastActivityUnix(session(createdAt = 100.0, lastIndex = 3, transcriptIndex = 3))
        clock.unix = 7_000
        assertEquals(7_000L, activity.lastActivityUnix(session(createdAt = 100.0, lastIndex = 3, transcriptIndex = 5)))
    }
}
