package pl.dmq.peering.session.agent.routines

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentRoutine
import pl.dmq.peering.wire.AgentRoutineSchedule

class AgentRoutineDraftTest {
    private val allModes = AgentPermissionMode.entries

    private fun filled() = AgentRoutineDraft.new("claude", allModes).copy(name = " Morning ", directory = "/work", prompt = "Review")

    @Test
    fun aNewRoutineIsWeekdayMorningsInTheMostCarefulUnattendedMode() {
        val draft = AgentRoutineDraft.new("claude", allModes)
        assertEquals(AgentRoutineSchedule.Daily(9, 0, listOf(2, 3, 4, 5, 6)), draft.schedule)
        assertEquals(AgentPermissionMode.PLAN, draft.permissionMode)
        assertTrue(draft.notifiesWhenDone)
        assertEquals(30, draft.stopAfterMinutes)
    }

    @Test
    fun theDefaultModeSkipsOnesTheAgentLacks() {
        assertEquals(AgentPermissionMode.ACCEPT_EDITS, AgentRoutineValidation.defaultMode(listOf(AgentPermissionMode.ACCEPT_EDITS, AgentPermissionMode.AUTO)))
        assertEquals(AgentPermissionMode.MANUAL, AgentRoutineValidation.defaultMode(listOf(AgentPermissionMode.AUTO)))
    }

    @Test
    fun theSentRoutineIsTrimmedAndCarriesTheNotifyChoice() {
        val routine = filled().copy(notifiesWhenDone = false).routine
        assertEquals("Morning", routine.name)
        assertEquals(false, routine.notifiesWhenDone)
        assertNull(routine.lastRun)
    }

    @Test
    fun anOldRoutineWithoutTheNotifyFieldOpensWithItOn() {
        val old = AgentRoutine("A", "n", "claude", "/w", "p", AgentRoutineSchedule.Every(30), AgentPermissionMode.PLAN, true)
        assertTrue(AgentRoutineDraft.of(old).notifiesWhenDone)
    }

    @Test
    fun wholeHoursOpenAsHoursAndOtherIntervalsAsMinutes() {
        val hours = AgentRoutineDraft.of(routine(AgentRoutineSchedule.Every(180)))
        assertEquals(RoutineIntervalUnit.HOURS, hours.intervalUnit)
        assertEquals(3, hours.intervalValue)
        val minutes = AgentRoutineDraft.of(routine(AgentRoutineSchedule.Every(45)))
        assertEquals(RoutineIntervalUnit.MINUTES, minutes.intervalUnit)
        assertEquals(AgentRoutineSchedule.Every(45), minutes.schedule)
        assertEquals(AgentRoutineSchedule.Every(180), hours.schedule)
    }

    @Test
    fun aDailyRoutineRoundTripsItsTimeAndDays() {
        val schedule = AgentRoutineSchedule.Daily(18, 30, listOf(1, 7))
        assertEquals(schedule, AgentRoutineDraft.of(routine(schedule)).schedule)
    }

    @Test
    fun switchingAgentKeepsTheModeOnlyWhenTheNewAgentOffersIt() {
        val draft = filled().copy(permissionMode = AgentPermissionMode.AUTO)
        assertEquals(AgentPermissionMode.AUTO, draft.withAgent("codex", allModes).permissionMode)
        assertEquals(AgentPermissionMode.PLAN, draft.withAgent("codex", listOf(AgentPermissionMode.PLAN)).permissionMode)
    }

    @Test
    fun changingTheUnitRestartsTheCountInRange() {
        assertEquals(30, filled().withUnit(RoutineIntervalUnit.MINUTES).intervalValue)
        assertEquals(1, filled().withUnit(RoutineIntervalUnit.HOURS).intervalValue)
    }

    @Test
    fun togglingAWeekdayAddsAndRemovesIt() {
        val draft = filled()
        assertEquals(setOf(3, 4, 5, 6), draft.toggling(2).weekdays)
        assertEquals(setOf(1, 2, 3, 4, 5, 6), draft.toggling(1).weekdays)
    }

    private fun routine(schedule: AgentRoutineSchedule) =
        AgentRoutine("A", "n", "claude", "/w", "p", schedule, AgentPermissionMode.PLAN, true, notifiesWhenDone = false)
}
