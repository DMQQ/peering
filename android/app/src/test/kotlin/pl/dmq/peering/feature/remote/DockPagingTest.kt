package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Test

class DockPagingTest {
    private val paging = DockPaging().apply { onPagesChanged(listOf("a", "b", "c", "d")) }

    @Test
    fun startsOnTheFirstPage() {
        assertEquals(0, paging.index)
    }

    @Test
    fun swipingForwardThenBackReturnsToTheFirstPage() {
        paging.onSettled(1)
        paging.onSettled(2)
        assertEquals(2, paging.index)
        paging.onSettled(1)
        paging.onSettled(0)
        assertEquals(0, paging.index)
    }

    @Test
    fun tappingADotJumpsStraightThere() {
        paging.select(3)
        assertEquals(3, paging.index)
        paging.select(0)
        assertEquals(0, paging.index)
    }

    @Test
    fun pagesBeyondTheEndsAreClamped() {
        paging.select(9)
        assertEquals(3, paging.index)
        paging.select(-2)
        assertEquals(0, paging.index)
    }

    @Test
    fun resetGoesBackToTheFirstPage() {
        paging.select(2)
        paging.reset()
        assertEquals(0, paging.index)
    }

    @Test
    fun aNewPageInFrontKeepsTheSamePageShown() {
        paging.select(1)
        paging.onPagesChanged(listOf("a", "x", "b", "c", "d"))
        assertEquals(2, paging.index)
    }

    @Test
    fun aVanishedPageFallsBackToTheFirst() {
        paging.select(1)
        paging.onPagesChanged(listOf("a", "c"))
        assertEquals(0, paging.index)
    }
}
