package pl.dmq.peering.wire

import kotlinx.serialization.decodeFromString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ClipboardPayloadTest {
    @Test
    fun textKindCarriesItsText() {
        val payload = WireJson.decodeFromString<ClipboardPayload>("""{"kind":"text","text":"hello"}""")

        assertEquals("hello", payload.plainText)
    }

    @Test
    fun anOlderHostSendsTextWithNoKind() {
        val payload = WireJson.decodeFromString<ClipboardPayload>("""{"text":"hello"}""")

        assertEquals("hello", payload.plainText)
    }

    @Test
    fun anImageHasNoPlainText() {
        val payload = WireJson.decodeFromString<ClipboardPayload>("""{"kind":"image","image":"AAAA"}""")

        assertNull(payload.plainText)
    }
}
