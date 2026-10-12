package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.wire.AgentTurnSummary

class TurnSummaryUiTest {
    @Test
    fun aCleanTurnIsDone() {
        val ui = TurnSummaryUi.of(AgentTurnSummary(ok = true, stopped = false, duration = 12.4, costUSD = 0.031))
        assertEquals(TurnStatus.DONE, ui.status)
        assertEquals(12L, ui.durationSeconds)
        assertEquals(0.031, ui.costUSD!!, 0.0001)
    }

    @Test
    fun aStoppedTurnIsStoppedEvenThoughItWasOk() {
        assertEquals(TurnStatus.STOPPED, TurnSummaryUi.of(AgentTurnSummary(ok = true, stopped = true)).status)
    }

    @Test
    fun aTurnThatIsNotOkFailedWhateverElseItSays() {
        assertEquals(TurnStatus.FAILED, TurnSummaryUi.of(AgentTurnSummary(ok = false, stopped = true)).status)
    }

    @Test
    fun unreportedFieldsStayAbsent() {
        val ui = TurnSummaryUi.of(AgentTurnSummary(ok = true, stopped = false))
        assertNull(ui.durationSeconds)
        assertNull(ui.costUSD)
    }

    @Test
    fun durationRoundsToTheNearestSecond() {
        assertEquals(13L, TurnSummaryUi.of(AgentTurnSummary(ok = true, stopped = false, duration = 12.5)).durationSeconds)
    }
}
