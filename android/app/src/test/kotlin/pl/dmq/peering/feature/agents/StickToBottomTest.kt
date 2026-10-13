package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StickToBottomTest {
    @Test
    fun startsFollowingWithNothingUnseen() {
        val state = StickToBottom()
        assertTrue(state.following)
        assertEquals(0, state.unseenRows(rowCount = 12))
    }

    @Test
    fun scrollingUpStopsFollowingAndCountsNewRowsAsUnseen() {
        val state = StickToBottom().userScrolled(atBottom = false, rowCount = 10)
        assertFalse(state.following)
        assertEquals(0, state.unseenRows(rowCount = 10))
        assertEquals(3, state.unseenRows(rowCount = 13))
    }

    @Test
    fun scrollingBackToTheBottomFollowsAgain() {
        val state = StickToBottom().userScrolled(atBottom = false, rowCount = 10).userScrolled(atBottom = true, rowCount = 14)
        assertTrue(state.following)
        assertEquals(0, state.unseenRows(rowCount = 20))
    }

    @Test
    fun scrollingWhileAlreadyDetachedKeepsTheOriginalCount() {
        val state = StickToBottom().userScrolled(atBottom = false, rowCount = 10).userScrolled(atBottom = false, rowCount = 15)
        assertEquals(5, state.unseenRows(rowCount = 15))
    }

    @Test
    fun sendingAPromptFollowsEvenWhenDetached() {
        val state = StickToBottom().userScrolled(atBottom = false, rowCount = 10).followLatest()
        assertTrue(state.following)
        assertEquals(0, state.unseenRows(rowCount = 11))
    }

    @Test
    fun aScrollAtTheBottomWhileFollowingChangesNothing() {
        val state = StickToBottom().userScrolled(atBottom = true, rowCount = 4)
        assertEquals(StickToBottom(), state)
    }
}
