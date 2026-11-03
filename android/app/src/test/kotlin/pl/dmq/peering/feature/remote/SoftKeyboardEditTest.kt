package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.feature.sessionmode.TypedDiff

class SoftKeyboardEditTest {
    private val sentinel = SoftKeyboardEdit.SENTINEL

    @Test
    fun `the untouched sentinel is no edit`() {
        assertEquals(TypedDiff("", 0), SoftKeyboardEdit.between(sentinel, sentinel))
    }

    @Test
    fun `a typed space is sent`() {
        assertEquals(TypedDiff(" ", 0), SoftKeyboardEdit.between(sentinel, "$sentinel "))
    }

    @Test
    fun `a word committed with its space keeps the space`() {
        assertEquals(TypedDiff(" ", 0), SoftKeyboardEdit.between("${sentinel}hello", "${sentinel}hello "))
    }

    @Test
    fun `an emptied field is one delete`() {
        assertEquals(TypedDiff("", 1), SoftKeyboardEdit.between(sentinel, ""))
    }

    @Test
    fun `a delete while composing takes back one character`() {
        assertEquals(TypedDiff("", 1), SoftKeyboardEdit.between("${sentinel}hel", "${sentinel}he"))
    }

    @Test
    fun `text that replaced the sentinel is typed without it`() {
        assertEquals(TypedDiff("x", 1), SoftKeyboardEdit.between(sentinel, "x"))
    }
}
