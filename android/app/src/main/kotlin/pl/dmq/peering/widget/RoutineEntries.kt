package pl.dmq.peering.widget

import pl.dmq.peering.wire.AgentRoutine
import pl.dmq.peering.wire.AgentRoutineOutcome

/** Maps the routines the Mac listed to the plain values the Routines widget needs. */
object RoutineEntries {
    private const val APPLE_EPOCH_OFFSET_SECONDS = 978_307_200L
    private const val MILLIS_PER_SECOND = 1_000L

    fun from(routines: List<AgentRoutine>): List<RoutineEntry> = routines
        .map { routine ->
            RoutineEntry(
                id = routine.id,
                name = WidgetLimits.text(routine.name),
                tone = tone(routine.lastRun?.outcome),
                nextRunAtMillis = routine.nextRunAt?.let { ((it + APPLE_EPOCH_OFFSET_SECONDS) * MILLIS_PER_SECOND).toLong() },
                isEnabled = routine.isEnabled,
            )
        }
        .sortedBy { if (it.tone == RoutineTone.RUNNING) 0 else 1 }
        .take(WidgetLimits.MAX_ROUTINES)

    private fun tone(outcome: AgentRoutineOutcome?): RoutineTone = when (outcome) {
        null -> RoutineTone.NEVER_RUN
        AgentRoutineOutcome.RUNNING -> RoutineTone.RUNNING
        AgentRoutineOutcome.SUCCEEDED -> RoutineTone.SUCCEEDED
        AgentRoutineOutcome.FAILED -> RoutineTone.FAILED
        AgentRoutineOutcome.STOPPED -> RoutineTone.STOPPED
        AgentRoutineOutcome.SKIPPED -> RoutineTone.SKIPPED
    }
}
