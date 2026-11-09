package pl.dmq.peering.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentRoutine
import pl.dmq.peering.wire.AgentRoutineOutcome
import pl.dmq.peering.wire.AgentRoutineRun
import pl.dmq.peering.wire.AgentRoutineSchedule

class WidgetRoutinesTest {
    private fun routine(id: String, outcome: AgentRoutineOutcome?, next: Double? = null, enabled: Boolean = true) = AgentRoutine(
        id, "R$id", "claude", "/w", "p", AgentRoutineSchedule.Every(60), AgentPermissionMode.PLAN, enabled,
        lastRun = outcome?.let { AgentRoutineRun(0.0, it) }, nextRunAt = next,
    )

    @Test
    fun runningRoutinesComeFirstAndKeepTheirOrderOtherwise() {
        val entries = RoutineEntries.from(
            listOf(routine("a", AgentRoutineOutcome.SUCCEEDED), routine("b", AgentRoutineOutcome.RUNNING), routine("c", null)),
        )
        assertEquals(listOf("b", "a", "c"), entries.map { it.id })
        assertEquals(RoutineTone.NEVER_RUN, entries.last().tone)
    }

    @Test
    fun theMacsDatesBecomeUnixMilliseconds() {
        val entry = RoutineEntries.from(listOf(routine("a", null, next = 0.0))).single()
        assertEquals(978_307_200_000L, entry.nextRunAtMillis)
    }

    @Test
    fun theSnapshotRoundTripsThroughItsText() {
        val snapshot = RoutinesSnapshot(
            listOf(RoutineEntry("a", "Nightly", RoutineTone.FAILED, 1_700_000_000_000L, true), RoutineEntry("b", "Off one", RoutineTone.NEVER_RUN, null, false)),
        )
        assertEquals(snapshot, WidgetCodec.decodeRoutines(WidgetCodec.encode(snapshot)))
    }

    @Test
    fun garbageReadsAsNoRoutines() {
        assertTrue(WidgetCodec.decodeRoutines("{nope").routines.isEmpty())
        assertTrue(WidgetCodec.decodeRoutines(null).routines.isEmpty())
    }

    @Test
    fun onlyChatsAskingForAnAnswerAreWaitingOnYou() {
        val chats = listOf(
            AgentChatEntry("1", null, "A", "f", AgentChatTone.WORKING, 0),
            AgentChatEntry("2", null, "B", "f", AgentChatTone.NEEDS_YOU, 0),
            AgentChatEntry("3", null, "C", "f", AgentChatTone.FINISHED, 0),
        )
        assertEquals(listOf("2"), AgentsSnapshot(chats).needingYou.map { it.id })
    }
}
