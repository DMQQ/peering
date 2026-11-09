package pl.dmq.peering.feature.agents.routines

import java.time.DayOfWeek
import java.time.format.TextStyle
import java.util.Locale

/** How a set of routine weekdays reads. Routines number the days as Swift's `Calendar` does: 1 is Sunday, 7 is Saturday. */
enum class WeekdayPattern { EVERY_DAY, WEEKDAYS, OTHER }

internal object RoutineWeekdays {
    fun pattern(days: Collection<Int>): WeekdayPattern = when (days.toSet()) {
        setOf(1, 2, 3, 4, 5, 6, 7) -> WeekdayPattern.EVERY_DAY
        setOf(2, 3, 4, 5, 6) -> WeekdayPattern.WEEKDAYS
        else -> WeekdayPattern.OTHER
    }

    fun dayOfWeek(routineDay: Int): DayOfWeek = if (routineDay == 1) DayOfWeek.SUNDAY else DayOfWeek.of(routineDay - 1)

    /** All seven days, starting from the locale's first day of the week. */
    fun ordered(first: DayOfWeek): List<Int> = (0 until 7).map { offset ->
        val day = first.plus(offset.toLong())
        if (day == DayOfWeek.SUNDAY) 1 else day.value + 1
    }

    fun shortName(routineDay: Int, locale: Locale): String = dayOfWeek(routineDay).getDisplayName(TextStyle.SHORT, locale)

    fun narrowName(routineDay: Int, locale: Locale): String = dayOfWeek(routineDay).getDisplayName(TextStyle.NARROW, locale)

    fun fullName(routineDay: Int, locale: Locale): String = dayOfWeek(routineDay).getDisplayName(TextStyle.FULL, locale)
}
