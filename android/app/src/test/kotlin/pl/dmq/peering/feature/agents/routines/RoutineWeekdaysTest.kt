package pl.dmq.peering.feature.agents.routines

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.DayOfWeek
import java.util.Locale

class RoutineWeekdaysTest {
    @Test
    fun theWeekRecognisesEveryDayAndWorkdays() {
        assertEquals(WeekdayPattern.EVERY_DAY, RoutineWeekdays.pattern(listOf(7, 6, 5, 4, 3, 2, 1)))
        assertEquals(WeekdayPattern.WEEKDAYS, RoutineWeekdays.pattern(listOf(2, 3, 4, 5, 6)))
        assertEquals(WeekdayPattern.OTHER, RoutineWeekdays.pattern(listOf(1, 7)))
    }

    @Test
    fun theWeekStartsWhereTheLocaleStartsIt() {
        assertEquals(listOf(1, 2, 3, 4, 5, 6, 7), RoutineWeekdays.ordered(DayOfWeek.SUNDAY))
        assertEquals(listOf(2, 3, 4, 5, 6, 7, 1), RoutineWeekdays.ordered(DayOfWeek.MONDAY))
        assertEquals(listOf(7, 1, 2, 3, 4, 5, 6), RoutineWeekdays.ordered(DayOfWeek.SATURDAY))
    }

    @Test
    fun oneIsSundayAndSevenIsSaturday() {
        assertEquals("Sunday", RoutineWeekdays.fullName(1, Locale.ENGLISH))
        assertEquals("Saturday", RoutineWeekdays.fullName(7, Locale.ENGLISH))
        assertEquals("Mon", RoutineWeekdays.shortName(2, Locale.ENGLISH))
    }
}
