package pl.dmq.peering.platform.store

import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PinCodecTest {
    private val key = ByteArray(65) { it.toByte() }

    @Test
    fun encodedPinsDecodeToTheSameKeys() {
        val decoded = PinCodec.decode(PinCodec.encode(mapOf("HOST-A" to key)))

        assertEquals(setOf("HOST-A"), decoded.keys)
        assertArrayEquals(key, decoded["HOST-A"])
    }

    @Test
    fun formatIsAJsonObjectOfBase64Keys() {
        val text = PinCodec.encode(mapOf("HOST-A" to key)).toString(Charsets.UTF_8)

        assertTrue(text.startsWith("{") && text.contains("\"HOST-A\""))
        assertTrue(text.contains(Base64.getEncoder().encodeToString(key)))
    }

    @Test
    fun missingBlobReadsAsNoPins() {
        assertTrue(PinCodec.decode(null).isEmpty())
    }

    @Test
    fun malformedJsonReadsAsNoPins() {
        assertTrue(PinCodec.decode("[1, 2".toByteArray()).isEmpty())
    }

    @Test
    fun keyOfTheWrongSizeIsDropped() {
        val short = Base64.getEncoder().encodeToString(ByteArray(10))

        assertTrue(PinCodec.decode("{\"SHORT\":\"$short\"}".toByteArray()).isEmpty())
    }

    @Test
    fun invalidBase64IsDropped() {
        assertTrue(PinCodec.decode("{\"HOST-A\":\"%%%\"}".toByteArray()).isEmpty())
    }
}
