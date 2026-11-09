package pl.dmq.peering.feature.agents.routines

import android.text.format.DateFormat
import android.text.format.DateUtils
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.session.agent.routines.AgentRoutineProblem
import pl.dmq.peering.wire.AgentRoutine
import pl.dmq.peering.wire.AgentRoutineOutcome
import pl.dmq.peering.wire.AgentRoutineRun
import pl.dmq.peering.wire.AgentRoutineSchedule
import java.util.Calendar
import java.util.Locale

/** Seconds from 1970-01-01 to 2001-01-01, the reference the Mac's dates count from. */
private const val APPLE_EPOCH_OFFSET_SECONDS = 978_307_200L
private const val MILLIS_PER_SECOND = 1_000L
private const val MINUTES_PER_HOUR = 60

internal fun appleSecondsToUnixMillis(seconds: Double): Long = ((seconds + APPLE_EPOCH_OFFSET_SECONDS) * MILLIS_PER_SECOND).toLong()

@Composable
internal fun clockText(hour: Int, minute: Int): String {
    val context = LocalContext.current
    val moment = Calendar.getInstance().apply {
        set(Calendar.HOUR_OF_DAY, hour)
        set(Calendar.MINUTE, minute)
    }
    return DateFormat.getTimeFormat(context).format(moment.time)
}

@Composable
internal fun durationText(minutes: Int): String =
    if (minutes % MINUTES_PER_HOUR == 0) {
        stringResource(R.string.routines_hours_short, minutes / MINUTES_PER_HOUR)
    } else {
        stringResource(R.string.routines_minutes_short, minutes)
    }

@Composable
internal fun scheduleText(schedule: AgentRoutineSchedule): String = when (schedule) {
    is AgentRoutineSchedule.Every -> stringResource(R.string.routines_every, durationText(schedule.minutes))
    is AgentRoutineSchedule.Daily -> {
        val time = clockText(schedule.hour, schedule.minute)
        when (RoutineWeekdays.pattern(schedule.weekdays)) {
            WeekdayPattern.EVERY_DAY -> stringResource(R.string.routines_every_day, time)
            WeekdayPattern.WEEKDAYS -> stringResource(R.string.routines_weekdays, time)
            WeekdayPattern.OTHER -> {
                val days = schedule.weekdays.sorted().joinToString(", ") { RoutineWeekdays.shortName(it, Locale.getDefault()) }
                stringResource(R.string.routines_days_at, days, time)
            }
        }
    }
}

@Composable
private fun relative(unixMillis: Long): String =
    DateUtils.getRelativeTimeSpanString(unixMillis, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()

@Composable
internal fun lastRunText(run: AgentRoutineRun?): String {
    if (run == null) return stringResource(R.string.routines_never_ran)
    val whenText = relative(appleSecondsToUnixMillis(run.startedAt))
    val line = when (run.outcome) {
        AgentRoutineOutcome.RUNNING -> stringResource(R.string.routines_last_running, whenText)
        AgentRoutineOutcome.SUCCEEDED -> stringResource(R.string.routines_last_finished, whenText)
        AgentRoutineOutcome.FAILED -> stringResource(R.string.routines_last_failed, whenText)
        AgentRoutineOutcome.STOPPED -> stringResource(R.string.routines_last_stopped, whenText)
        AgentRoutineOutcome.SKIPPED -> stringResource(R.string.routines_last_skipped, whenText)
    }
    return run.detail?.let { "$line. $it" } ?: line
}

@Composable
internal fun nextRunText(routine: AgentRoutine): String? {
    if (!routine.isEnabled) return stringResource(R.string.routines_off)
    val next = routine.nextRunAt ?: return null
    return stringResource(R.string.routines_next, relative(appleSecondsToUnixMillis(next)))
}

@Composable
internal fun problemText(problem: AgentRoutineProblem): String = stringResource(
    when (problem) {
        AgentRoutineProblem.MISSING_NAME -> R.string.routines_problem_name
        AgentRoutineProblem.NAME_TOO_LONG -> R.string.routines_problem_name_long
        AgentRoutineProblem.MISSING_PROMPT -> R.string.routines_problem_prompt
        AgentRoutineProblem.PROMPT_TOO_LONG -> R.string.routines_problem_prompt_long
        AgentRoutineProblem.RELATIVE_FOLDER -> R.string.routines_problem_folder
        AgentRoutineProblem.INTERVAL_OUT_OF_RANGE -> R.string.routines_problem_interval
        AgentRoutineProblem.TIME_OUT_OF_RANGE -> R.string.routines_problem_time
        AgentRoutineProblem.NO_WEEKDAYS -> R.string.routines_problem_days
        AgentRoutineProblem.STOP_AFTER_OUT_OF_RANGE -> R.string.routines_problem_stop
    },
)

@Composable
internal fun routineCountText(count: Int): String = pluralStringResource(R.plurals.routines_on_computer, count, count)
