package pl.dmq.peering.ui.kit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WidthClassTest {
    @Test
    fun `widths fall into Material's three steps at 600 and 840`() {
        assertEquals(WidthClass.Compact, WidthClass.of(360))
        assertEquals(WidthClass.Compact, WidthClass.of(599))
        assertEquals(WidthClass.Medium, WidthClass.of(600))
        assertEquals(WidthClass.Medium, WidthClass.of(839))
        assertEquals(WidthClass.Expanded, WidthClass.of(840))
        assertEquals(WidthClass.Expanded, WidthClass.of(1280))
    }

    @Test
    fun `only the expanded step has room for two panes`() {
        assertFalse(WidthClass.Compact.twoPane)
        assertFalse(WidthClass.Medium.twoPane)
        assertTrue(WidthClass.Expanded.twoPane)
    }
}
