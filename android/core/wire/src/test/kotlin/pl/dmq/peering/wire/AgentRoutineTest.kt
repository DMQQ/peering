package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentRoutineTest {
    private val id = "0A1B2C3D-0000-4000-8000-00000000000F"

    private val hostJson = """{"routines":{"_0":[{"id":"$id","name":"Nightly","agentID":"codex","directory":"/w","prompt":"Test","schedule":{"every":{"minutes":90}},"permissionMode":"acceptEdits","isEnabled":false,"lastRun":{"startedAt":780000000.5,"outcome":"skipped","detail":"Busy"},"nextRunAt":780005400.0}]}}"""

    @Test
    fun aRoutineFromAnOlderHostWithoutTheNotifyFieldReadsAsNotifying() {
        val event = AgentEvent.parse(hostJson) as AgentEvent.Routines
        val routine = event.decoded().single()
        assertNull(routine.notifiesWhenDone)
        assertTrue(routine.notifies)
        assertFalse(routine.isEnabled)
        assertEquals(AgentRoutineSchedule.Every(90), routine.schedule)
        assertEquals(AgentRoutineOutcome.SKIPPED, routine.lastRun?.outcome)
        assertEquals(780005400.0, routine.nextRunAt!!, 0.0)
    }

    @Test
    fun anUnsetNotifyFieldIsLeftOutAndFalseIsWritten() {
        val base = AgentRoutine(id, "A", "claude", "/w", "p", AgentRoutineSchedule.Every(30), AgentPermissionMode.MANUAL, false)
        assertFalse(AgentRequest.SaveRoutine(base).toJson().contains("notifiesWhenDone"))
        val off = AgentRequest.SaveRoutine(base.copy(notifiesWhenDone = false)).toJson()
        assertTrue(off.contains(""""notifiesWhenDone":false"""))
        assertTrue(off.contains(""""isEnabled":false"""))
    }

    @Test
    fun aRoutineTheHostWroteThatCannotBeReadIsDroppedNotFatal() {
        val json = """{"routines":{"_0":[{"id":"x"},{"id":"$id","name":"N","agentID":"a","directory":"/","prompt":"p","schedule":{"daily":{"hour":7,"minute":5,"weekdays":[1]}},"permissionMode":"auto","isEnabled":true}]}}"""
        val routines = (AgentEvent.parse(json) as AgentEvent.Routines).decoded()
        assertEquals(1, routines.size)
        assertEquals(AgentRoutineSchedule.Daily(7, 5, listOf(1)), routines.single().schedule)
    }
}
