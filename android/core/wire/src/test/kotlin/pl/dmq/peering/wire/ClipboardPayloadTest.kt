package pl.dmq.peering.wire

import kotlinx.serialization.decodeFromString
import org.junit.Assert.assertArrayEquals
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

    @Test
    fun anImageKindYieldsItsPng() {
        val payload = WireJson.decodeFromString<ClipboardPayload>("""{"kind":"image","image":"AQID"}""")

        assertArrayEquals(byteArrayOf(1, 2, 3), payload.pngBytes)
    }

    @Test
    fun aPictureOverTheLimitYieldsNothing() {
        val big = ByteArray(MAX_CLIPBOARD_IMAGE_BYTES + 1).toBase64()
        val payload = ClipboardPayload(kind = "image", image = big)

        assertNull(payload.pngBytes)
    }

    @Test
    fun textHasNoPngAndBadBase64YieldsNothing() {
        assertNull(ClipboardPayload(kind = "text", text = "x").pngBytes)
        assertNull(ClipboardPayload(kind = "image", image = "!!!").pngBytes)
    }
}
