package pl.dmq.peering.session.history

import org.junit.Assert.assertEquals
import org.junit.Test

class SessionTrailTest {
    @Test
    fun anEntryIsStampedWithSecondsSinceTheSessionBegan() {
        val trail = SessionTrail(beganAtMillis = 10_000)

        trail.add("dialling", atMillis = 12_900)

        assertEquals(listOf("+2s dialling"), trail.entries)
    }

    @Test
    fun aClockSetBackStampsZeroRatherThanNegative() {
        val trail = SessionTrail(beganAtMillis = 10_000)

        trail.add("late", atMillis = 5_000)

        assertEquals(listOf("+0s late"), trail.entries)
    }

    @Test
    fun onlyTheNewestEntriesAreKept() {
        val trail = SessionTrail(beganAtMillis = 0, limit = 2)

        listOf("a", "b", "c").forEachIndexed { index, text -> trail.add(text, atMillis = index * 1_000L) }

        assertEquals(listOf("+1s b", "+2s c"), trail.entries)
    }
}
