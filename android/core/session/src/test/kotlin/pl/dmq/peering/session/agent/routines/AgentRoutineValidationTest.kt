package pl.dmq.peering.session.agent.routines

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.wire.AgentRoutineSchedule

class AgentRoutineValidationTest {
    private fun draft() = AgentRoutineDraft.new("claude", listOf()).copy(name = "N", directory = "/w", prompt = "p")

    @Test
    fun aCompleteRoutineHasNoProblem() {
        assertNull(draft().problem)
    }

    @Test
    fun nameAndPromptMustHaveContent() {
        assertEquals(AgentRoutineProblem.MISSING_NAME, draft().copy(name = "  ").problem)
        assertEquals(AgentRoutineProblem.NAME_TOO_LONG, draft().copy(name = "x".repeat(81)).problem)
        assertEquals(AgentRoutineProblem.MISSING_PROMPT, draft().copy(prompt = "\n ").problem)
        assertEquals(AgentRoutineProblem.PROMPT_TOO_LONG, draft().copy(prompt = "x".repeat(64 * 1024 + 1)).problem)
    }

    @Test
    fun theFolderMustBeAbsolute() {
        assertEquals(AgentRoutineProblem.RELATIVE_FOLDER, draft().copy(directory = null).problem)
        assertEquals(AgentRoutineProblem.RELATIVE_FOLDER, draft().copy(directory = "work").problem)
    }

    @Test
    fun intervalsRunFromFifteenMinutesToAWeek() {
        val interval = draft().copy(cadence = RoutineCadence.INTERVAL, intervalUnit = RoutineIntervalUnit.MINUTES)
        assertEquals(AgentRoutineProblem.INTERVAL_OUT_OF_RANGE, interval.copy(intervalValue = 14).problem)
        assertNull(interval.copy(intervalValue = 15).problem)
        val hours = interval.copy(intervalUnit = RoutineIntervalUnit.HOURS)
        assertNull(hours.copy(intervalValue = 168).problem)
        assertEquals(AgentRoutineProblem.INTERVAL_OUT_OF_RANGE, hours.copy(intervalValue = 169).problem)
    }

    @Test
    fun aDailyRoutineNeedsADayAndARealTime() {
        assertEquals(AgentRoutineProblem.NO_WEEKDAYS, draft().copy(weekdays = emptySet()).problem)
        assertEquals(AgentRoutineProblem.TIME_OUT_OF_RANGE, draft().copy(hour = 24).problem)
        assertEquals(AgentRoutineProblem.TIME_OUT_OF_RANGE, draft().copy(minute = 60).problem)
        assertEquals(AgentRoutineProblem.NO_WEEKDAYS, AgentRoutineValidation.problem(draft().routine.copy(schedule = AgentRoutineSchedule.Daily(9, 0, listOf(8)))))
    }

    @Test
    fun theTimeLimitCannotPassTwelveHours() {
        assertNull(draft().copy(stopAfterMinutes = null).problem)
        assertEquals(AgentRoutineProblem.STOP_AFTER_OUT_OF_RANGE, draft().copy(stopAfterMinutes = 721).problem)
        assertEquals(AgentRoutineProblem.STOP_AFTER_OUT_OF_RANGE, draft().copy(stopAfterMinutes = 0).problem)
    }
}
