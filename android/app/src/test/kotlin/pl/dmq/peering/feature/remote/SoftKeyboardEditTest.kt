package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Test

class SoftKeyboardEditTest {
    @Test
    fun `the untouched sentinel is no edit`() {
        assertEquals(SoftKeyboardEdit.None, SoftKeyboardEdit.of(SoftKeyboardEdit.SENTINEL))
    }

    @Test
    fun `text after the sentinel is what was typed`() {
        assertEquals(SoftKeyboardEdit.Typed("ok"), SoftKeyboardEdit.of(" ok"))
    }

    @Test
    fun `an emptied field is a delete`() {
        assertEquals(SoftKeyboardEdit.Deleted, SoftKeyboardEdit.of(""))
    }

    @Test
    fun `text that replaced the sentinel is typed without it`() {
        assertEquals(SoftKeyboardEdit.Typed("x"), SoftKeyboardEdit.of("x"))
    }
}
