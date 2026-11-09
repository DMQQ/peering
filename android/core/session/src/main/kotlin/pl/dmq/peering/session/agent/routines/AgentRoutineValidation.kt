package pl.dmq.peering.session.agent.routines

import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentRoutine
import pl.dmq.peering.wire.AgentRoutineSchedule

/** What makes a routine one the Mac refuses to keep. */
enum class AgentRoutineProblem {
    MISSING_NAME,
    NAME_TOO_LONG,
    MISSING_PROMPT,
    PROMPT_TOO_LONG,
    RELATIVE_FOLDER,
    INTERVAL_OUT_OF_RANGE,
    TIME_OUT_OF_RANGE,
    NO_WEEKDAYS,
    STOP_AFTER_OUT_OF_RANGE,
}

object AgentRoutineValidation {
    const val NAME_LIMIT = 80
    const val PROMPT_BYTES_LIMIT = 64 * 1024

    /** Shorter than this, a run would still be going when the next is due. */
    const val MINIMUM_INTERVAL_MINUTES = 15
    const val MAXIMUM_INTERVAL_MINUTES = 7 * 24 * 60
    const val MAXIMUM_STOP_AFTER_MINUTES = 12 * 60

    /** The first problem found, or null for a routine that can be kept. */
    fun problem(routine: AgentRoutine): AgentRoutineProblem? {
        val name = routine.name.trim()
        if (name.isEmpty()) return AgentRoutineProblem.MISSING_NAME
        if (name.codePointCount(0, name.length) > NAME_LIMIT) return AgentRoutineProblem.NAME_TOO_LONG
        if (routine.prompt.isBlank()) return AgentRoutineProblem.MISSING_PROMPT
        if (routine.prompt.toByteArray(Charsets.UTF_8).size > PROMPT_BYTES_LIMIT) return AgentRoutineProblem.PROMPT_TOO_LONG
        if (!routine.directory.startsWith("/")) return AgentRoutineProblem.RELATIVE_FOLDER
        problem(routine.schedule)?.let { return it }
        val limit = routine.stopAfterMinutes
        if (limit != null && limit !in 1..MAXIMUM_STOP_AFTER_MINUTES) return AgentRoutineProblem.STOP_AFTER_OUT_OF_RANGE
        return null
    }

    private fun problem(schedule: AgentRoutineSchedule): AgentRoutineProblem? = when (schedule) {
        is AgentRoutineSchedule.Every ->
            if (schedule.minutes in MINIMUM_INTERVAL_MINUTES..MAXIMUM_INTERVAL_MINUTES) null else AgentRoutineProblem.INTERVAL_OUT_OF_RANGE
        is AgentRoutineSchedule.Daily -> when {
            schedule.hour !in 0..23 || schedule.minute !in 0..59 -> AgentRoutineProblem.TIME_OUT_OF_RANGE
            schedule.weekdays.isEmpty() || schedule.weekdays.any { it !in 1..7 } -> AgentRoutineProblem.NO_WEEKDAYS
            else -> null
        }
    }

    /** The permission mode a new routine starts in: the most careful one the agent offers that can still finish without anyone there. */
    fun defaultMode(among: List<AgentPermissionMode>): AgentPermissionMode =
        listOf(AgentPermissionMode.PLAN, AgentPermissionMode.ACCEPT_EDITS, AgentPermissionMode.MANUAL).firstOrNull { it in among }
            ?: AgentPermissionMode.MANUAL
}
