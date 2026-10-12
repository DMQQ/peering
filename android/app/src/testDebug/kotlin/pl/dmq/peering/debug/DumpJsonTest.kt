package pl.dmq.peering.debug

import org.junit.Assert.assertEquals
import org.junit.Test

class DumpJsonTest {
    @Test
    fun `values render in order with nulls and nesting`() {
        val json = DumpJson.render(
            linkedMapOf("tab" to "connect", "frames" to 12L, "live" to true, "none" to null, "at" to mapOf("agents" to true), "list" to listOf("a", 1)),
        )
        assertEquals("""{"tab":"connect","frames":12,"live":true,"none":null,"at":{"agents":true},"list":["a",1]}""", json)
    }

    @Test
    fun `strings are escaped`() {
        assertEquals("""{"k":"a\"b\\c\nd"}""", DumpJson.render(mapOf("k" to "a\"b\\c\nd")))
    }

    @Test
    fun `a non finite number becomes null`() {
        assertEquals("""{"x":null}""", DumpJson.render(mapOf("x" to Double.NaN)))
    }
}
