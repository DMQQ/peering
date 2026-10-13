package pl.dmq.peering.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DisconnectLinkTest {
    @Test
    fun `a disconnect link round trips and names no computer`() {
        assertEquals("peering://disconnect", WidgetLink.disconnect())
        assertEquals(WidgetLink.Disconnect, WidgetLink.parse(WidgetLink.disconnect()))
        assertNull(WidgetLink.Disconnect.targetHostId)
    }

    @Test
    fun `an unknown command is still rejected`() {
        assertNull(WidgetLink.parse("peering://end-shells"))
        assertNull(WidgetLink.parse("peering://wipe"))
    }
}
