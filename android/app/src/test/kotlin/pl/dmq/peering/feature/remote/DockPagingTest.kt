package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DockPagingTest {
    private fun chords(count: Int) = List(count) { QuickAction("c$it", "k$it", "l$it", it, 0L) }

    private fun groups(app: Int = 0, edits: Int = 2): List<DockGroup> {
        val base = DockGroups.of(profile = null, edits = chords(edits))
        return if (app == 0) base else listOf(base[0], DockGroup("app-x", emptyList(), chords(app))) + base.drop(1)
    }

    @Test
    fun controlsFillPagesInOrderWithTheRemainderOnTheLast() {
        val pages = DockPaging.layout(groups(edits = 0), 5).pages
        assertEquals(listOf(5, 5, 3), pages.map { it.size })
        assertEquals(DockControl.SOURCES, pages[0][0].control)
        assertEquals(DockControl.SETTINGS, pages[2][2].control)
    }

    @Test
    fun aGroupBeginningMidPageContinuesOnThatPage() {
        val laid = DockPaging.layout(groups(app = 4), 5)
        assertEquals(2, laid.firstPageOfGroup["app-x"])
        assertEquals(2, laid.pageOfApplication())
        assertEquals(3, laid.pages[2].count { it.control != null })
        assertEquals(2, laid.pages[2].count { it.action != null })
    }

    @Test
    fun aGroupStartingOnAFullPageGoesToTheNext() {
        val full = DockGroup("controls", DockControl.entries.take(5), emptyList())
        val laid = DockPaging.layout(listOf(full, DockGroup("app-x", emptyList(), chords(3))), 5)
        assertEquals(2, laid.pages.size)
        assertEquals(1, laid.pageOfApplication())
    }

    @Test
    fun noApplicationMeansNoApplicationPage() {
        assertNull(DockPaging.layout(groups(), 5).pageOfApplication())
    }

    @Test
    fun onlyTheFirstSlotOfEachGroupStartsIt() {
        val slots = DockPaging.layout(groups(app = 3), 4).pages.flatten()
        assertEquals(3, slots.count { it.startsGroup })
        assertTrue(slots.first().startsGroup)
    }

    @Test
    fun perPageFitsTheWidthAndStaysInRange() {
        assertEquals(5, DockPaging.perPage(400f, 64f))
        assertEquals(4, DockPaging.perPage(278f, 64f))
        assertEquals(3, DockPaging.perPage(120f, 64f))
    }
}
