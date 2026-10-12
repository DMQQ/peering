package pl.dmq.peering.widget

import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull

class LockedLinkQueueTest {
    @Test
    fun `an unlocked app acts on the link at once`() {
        val queue = LockedLinkQueue()
        assertEquals(WidgetLink.Connect("a"), queue.admit(WidgetLink.Connect("a"), locked = false))
        assertNull(queue.release())
    }

    @Test
    fun `a locked app holds the link and replays it once after unlock`() {
        val queue = LockedLinkQueue()
        assertNull(queue.admit(WidgetLink.Connect("a"), locked = true))
        assertEquals(WidgetLink.Connect("a"), queue.release())
        assertNull(queue.release())
    }

    @Test
    fun `a later link replaces an earlier held one`() {
        val queue = LockedLinkQueue()
        queue.admit(WidgetLink.Connect("a"), locked = true)
        queue.admit(WidgetLink.Chat("c", "b"), locked = true)
        assertEquals(WidgetLink.Chat("c", "b"), queue.release())
    }
}
