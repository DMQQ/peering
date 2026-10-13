package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TextFieldFollowerTest {
    private val follower = TextFieldFollower()

    private fun focus(
        editable: Boolean,
        keyboardShown: Boolean = false,
        enabled: Boolean = true,
        observing: Boolean = false,
        mosaic: Boolean = false,
        panelOpen: Boolean = false,
    ) = follower.onFocus(editable, enabled, observing, mosaic, panelOpen, keyboardShown)

    @Test
    fun `focusing a text field opens the keyboard and leaving it closes the keyboard that was opened`() {
        assertEquals(KeyboardMove.OPEN, focus(editable = true))
        assertEquals(KeyboardMove.CLOSE, focus(editable = false, keyboardShown = true))
    }

    @Test
    fun `a keyboard raised by hand stays when the focus leaves`() {
        assertEquals(KeyboardMove.NONE, focus(editable = true, keyboardShown = true))
        assertEquals(KeyboardMove.NONE, focus(editable = false, keyboardShown = true))
    }

    @Test
    fun `a keyboard the person took over is theirs to close`() {
        focus(editable = true)
        follower.keyboardToggledByHand()

        assertEquals(KeyboardMove.NONE, focus(editable = false, keyboardShown = true))
    }

    @Test
    fun `nothing happens with the setting off, while watching, in a mosaic or with a panel open`() {
        assertEquals(KeyboardMove.NONE, focus(editable = true, enabled = false))
        assertEquals(KeyboardMove.NONE, focus(editable = true, observing = true))
        assertEquals(KeyboardMove.NONE, focus(editable = true, mosaic = true))
        assertEquals(KeyboardMove.NONE, focus(editable = true, panelOpen = true))
    }

    @Test
    fun `a report waits while the person types and shows once they stop`() {
        val mirror = FieldMirror(settleMillis = 800)
        mirror.onLocalEdit(1_000)

        assertNull(mirror.onReport("hello", nowMillis = 1_300))
        assertEquals(500L, mirror.waitMillis(1_300))
        assertNull(mirror.release(1_700))
        assertEquals("hello", mirror.release(1_800))
        assertNull(mirror.waitMillis(1_800))
    }

    @Test
    fun `a report with nobody typing shows at once and a newer one replaces a waiting one`() {
        val mirror = FieldMirror(settleMillis = 800)

        assertEquals("first", mirror.onReport("first", nowMillis = 0))

        mirror.onLocalEdit(10_000)
        assertNull(mirror.onReport("second", 10_100))
        assertNull(mirror.onReport("third", 10_200))
        assertEquals("third", mirror.release(11_000))
    }

    @Test
    fun `a field with no text and a moved focus drop what was waiting`() {
        val mirror = FieldMirror(settleMillis = 800)
        mirror.onLocalEdit(0)
        mirror.onReport("held", 100)

        mirror.reset()

        assertNull(mirror.release(5_000))
        assertNull(mirror.onReport(null, 5_000))
    }
}
