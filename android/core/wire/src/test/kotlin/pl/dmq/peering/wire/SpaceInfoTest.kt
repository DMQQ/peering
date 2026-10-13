package pl.dmq.peering.wire

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SpaceInfoTest {
    private fun parse(text: String) = SpaceInfo.parse(Json.parseToJsonElement(text))

    @Test
    fun `a display with desktops reads its count, current desktop and previews`() {
        val info = parse("""{"displays":[{"displayID":7,"count":3,"current":2,"previews":[{"index":2,"width":1600,"height":1000,"jpegData":"AAEC"}]}]}""")!!

        val display = info.display(7)!!
        assertEquals(3, display.count)
        assertEquals(2, display.current)
        assertEquals(1.6f, display.preview(2)!!.shape)
        assertNull(display.preview(1))
    }

    @Test
    fun `a full screen app leaves no current desktop`() {
        val info = parse("""{"displays":[{"displayID":1,"count":2}]}""")!!

        assertNull(info.displays.single().current)
        assertTrue(info.displays.single().previews.isEmpty())
    }

    @Test
    fun `the flat shape of an older host reads as one display with id zero`() {
        val info = parse("""{"count":4,"current":1,"previews":[]}""")!!

        assertEquals(0L, info.displays.single().displayId)
        assertEquals(4, info.totalCount)
    }

    @Test
    fun `desktops are shown for two desktops or two screens, not for one of each`() {
        assertFalse(parse("""{"displays":[{"displayID":1,"count":1,"current":1}]}""")!!.showsDesktops)
        assertTrue(parse("""{"displays":[{"displayID":1,"count":2,"current":1}]}""")!!.showsDesktops)
        assertTrue(parse("""{"displays":[{"displayID":1,"count":1,"current":1},{"displayID":2,"count":1,"current":1}]}""")!!.showsDesktops)
    }

    @Test
    fun `a missing or unreadable payload is no desktop information`() {
        assertNull(SpaceInfo.parse(null))
        assertNull(parse("""{"unrelated":true}"""))
    }
}
