package pl.dmq.peering.session.agent.routines

import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentRoutine
import pl.dmq.peering.wire.AgentRoutineSchedule
import java.util.UUID

enum class RoutineCadence { INTERVAL, DAILY }

enum class RoutineIntervalUnit { MINUTES, HOURS }

/** A routine as its editor holds it: the schedule split into the fields the form shows. [directory] is null until a folder is picked. */
data class AgentRoutineDraft(
    val id: String,
    val name: String = "",
    val agentID: String,
    val directory: String? = null,
    val prompt: String = "",
    val cadence: RoutineCadence = RoutineCadence.DAILY,
    val intervalValue: Int = 1,
    val intervalUnit: RoutineIntervalUnit = RoutineIntervalUnit.HOURS,
    val hour: Int = 9,
    val minute: Int = 0,
    val weekdays: Set<Int> = WEEKDAYS,
    val permissionMode: AgentPermissionMode,
    val isEnabled: Boolean = true,
    val stopAfterMinutes: Int? = 30,
    val notifiesWhenDone: Boolean = true,
) {
    val schedule: AgentRoutineSchedule
        get() = when (cadence) {
            RoutineCadence.INTERVAL ->
                AgentRoutineSchedule.Every(if (intervalUnit == RoutineIntervalUnit.HOURS) intervalValue * 60 else intervalValue)
            RoutineCadence.DAILY -> AgentRoutineSchedule.Daily(hour, minute, weekdays.sorted())
        }

    /** What is sent to the Mac. The last run and the next one are the Mac's to keep. */
    val routine: AgentRoutine
        get() = AgentRoutine(
            id = id,
            name = name.trim(),
            agentID = agentID,
            directory = directory.orEmpty(),
            prompt = prompt,
            schedule = schedule,
            permissionMode = permissionMode,
            isEnabled = isEnabled,
            stopAfterMinutes = stopAfterMinutes,
            notifiesWhenDone = notifiesWhenDone,
        )

    val problem: AgentRoutineProblem? get() = AgentRoutineValidation.problem(routine)

    /** Switching agent keeps the mode when the new agent offers it, else falls back to the default one. */
    fun withAgent(agentID: String, modes: List<AgentPermissionMode>): AgentRoutineDraft = copy(
        agentID = agentID,
        permissionMode = if (permissionMode in modes) permissionMode else AgentRoutineValidation.defaultMode(modes),
    )

    /** Changing the unit restarts the count at a value that is in range for it. */
    fun withUnit(unit: RoutineIntervalUnit): AgentRoutineDraft =
        copy(intervalUnit = unit, intervalValue = if (unit == RoutineIntervalUnit.HOURS) 1 else DEFAULT_INTERVAL_MINUTES)

    fun toggling(weekday: Int): AgentRoutineDraft =
        copy(weekdays = if (weekday in weekdays) weekdays - weekday else weekdays + weekday)

    companion object {
        /** Monday to Friday, numbered with 1 as Sunday. */
        val WEEKDAYS: Set<Int> = setOf(2, 3, 4, 5, 6)
        private const val DEFAULT_INTERVAL_MINUTES = 30
        private const val MINUTES_PER_HOUR = 60

        /** Weekday mornings at nine, in the agent's most careful mode that runs unattended. */
        fun new(agentID: String, modes: List<AgentPermissionMode>): AgentRoutineDraft = AgentRoutineDraft(
            id = UUID.randomUUID().toString().uppercase(),
            agentID = agentID,
            permissionMode = AgentRoutineValidation.defaultMode(modes),
        )

        fun of(routine: AgentRoutine): AgentRoutineDraft {
            val base = AgentRoutineDraft(
                id = routine.id,
                name = routine.name,
                agentID = routine.agentID,
                directory = routine.directory,
                prompt = routine.prompt,
                permissionMode = routine.permissionMode,
                isEnabled = routine.isEnabled,
                stopAfterMinutes = routine.stopAfterMinutes,
                notifiesWhenDone = routine.notifies,
            )
            return when (val schedule = routine.schedule) {
                is AgentRoutineSchedule.Every -> {
                    val wholeHours = schedule.minutes % MINUTES_PER_HOUR == 0
                    base.copy(
                        cadence = RoutineCadence.INTERVAL,
                        intervalUnit = if (wholeHours) RoutineIntervalUnit.HOURS else RoutineIntervalUnit.MINUTES,
                        intervalValue = if (wholeHours) schedule.minutes / MINUTES_PER_HOUR else schedule.minutes,
                    )
                }
                is AgentRoutineSchedule.Daily ->
                    base.copy(cadence = RoutineCadence.DAILY, hour = schedule.hour, minute = schedule.minute, weekdays = schedule.weekdays.toSet())
            }
        }
    }
}
