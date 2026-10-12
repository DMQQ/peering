package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Test

class FunctionKeyTest {
    @Test
    fun `the row holds F1 to F12 with the keymap vector keycodes`() {
        val codes = FunctionKey.entries.map { it.macKeyCode }

        assertEquals(12, FunctionKey.entries.size)
        assertEquals(listOf(122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111), codes)
    }
}
