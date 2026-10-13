package pl.dmq.peering.wire

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class FramingTest {
    private val wire = VectorFiles.load("wire.json").jsonObject

    @Test
    fun encodesEveryVectorFrameToTheSharedBytes() {
        for (case in wire["frames"]!!.jsonArray) {
            val item = case.jsonObject
            val kind = MessageKind.fromByte(item.int("kind"))!!
            val encoded = FrameEncoder.encode(kind, item.text("payload").hexToBytes())
            assertEquals(item.text("name"), item.text("bytes"), encoded.toHex())
        }
    }

    @Test
    fun deliversFramesSplitAndCoalescedAcrossReads() {
        val vector = wire["decoderSplit"]!!.jsonObject
        val feeds = vector["feeds"]!!.jsonArray
        val expected = vector["framesAfterEachFeed"]!!.jsonArray
        val decoder = FrameDecoder()
        for ((feed, want) in feeds.zip(expected)) {
            decoder.push(feed.jsonPrimitive.content.hexToBytes())
            val got = generateSequence { decoder.next() }.map { it.kind.byte to it.payload.toHex() }.toList()
            val wanted = want.jsonArray.map { it.jsonObject.int("kind") to it.jsonObject.text("payload") }
            assertEquals(wanted, got)
        }
    }

    @Test
    fun rejectsEveryVectorErrorBeforeBufferingThePayload() {
        for (case in wire["decoderErrors"]!!.jsonArray) {
            val item = case.jsonObject
            val decoder = FrameDecoder()
            decoder.push(item.text("bytes").hexToBytes())
            val error = runCatching { decoder.next() }.exceptionOrNull()
            val name = when (error) {
                ZeroLength -> "zeroLength"
                is FrameTooLarge -> "tooLarge"
                is UnknownKind -> "unknownKind"
                else -> error?.javaClass?.simpleName ?: "no error"
            }
            assertEquals(item.text("name"), item.text("error"), name)
        }
    }

    @Test
    fun aDeclaredLengthOverTheLimitIsReportedWithItsValue() {
        val decoder = FrameDecoder()
        decoder.push(byteArrayOf(0x01, 0x00, 0x00, 0x01, 0x00))
        val error = runCatching { decoder.next() }.exceptionOrNull() as FrameTooLarge
        assertEquals(MAX_FRAME_LENGTH + 1, error.declared)
    }

    @Test
    fun aDeclaredLengthAtTheLimitWaitsForItsPayload() {
        val decoder = FrameDecoder()
        decoder.push(byteArrayOf(0x01, 0x00, 0x00, 0x00))
        assertNull(decoder.next())
        assertEquals(4, decoder.buffered)
    }

    @Test
    fun anUnknownKindIsNotConsumed() {
        val decoder = FrameDecoder()
        decoder.push("000000017f".hexToBytes())
        val error = runCatching { decoder.next() }.exceptionOrNull() as UnknownKind
        assertEquals(0x7f, error.byte)
        assertEquals(5, decoder.buffered)
    }

    @Test
    fun waitsForTheRestOfAPartialFrame() {
        val decoder = FrameDecoder()
        val whole = FrameEncoder.encode(MessageKind.Ping, "{}".toByteArray())
        decoder.push(whole.copyOfRange(0, whole.size - 1))
        assertNull(decoder.next())
        decoder.push(whole.copyOfRange(whole.size - 1, whole.size))
        assertArrayEquals("{}".toByteArray(), decoder.next()!!.payload)
        assertEquals(0, decoder.buffered)
    }

    @Test
    fun waitsForAFramesLengthPrefixToArrive() {
        val decoder = FrameDecoder()
        decoder.push(byteArrayOf(0x00, 0x00))
        assertNull(decoder.next())
        decoder.push(byteArrayOf(0x00, 0x01, 0x0B))
        assertEquals(Frame(MessageKind.Ping, ByteArray(0)), decoder.next())
    }

    @Test
    fun aLargeFrameArrivingInSmallPiecesIsReassembled() {
        val payload = ByteArray(300_000) { (it % 251).toByte() }
        val whole = FrameEncoder.encode(MessageKind.VideoChunk, payload)
        val decoder = FrameDecoder()
        var frame: Frame? = null
        for (offset in whole.indices step 997) {
            decoder.push(whole.copyOfRange(offset, minOf(offset + 997, whole.size)))
            frame = frame ?: decoder.next()
        }
        assertEquals(Frame(MessageKind.VideoChunk, payload), frame)
    }

    @Test
    fun everyKindRoundTripsThroughItsByte() {
        for (kind in MessageKind.entries) {
            assertEquals(kind, MessageKind.fromByte(kind.byte))
            val decoder = FrameDecoder()
            decoder.push(FrameEncoder.encode(kind, byteArrayOf(1, 2, 3)))
            assertEquals(Frame(kind, byteArrayOf(1, 2, 3)), decoder.next())
        }
    }

    @Test
    fun onlyTheDefinedBytesHaveAKind() {
        val defined = (0..255).filter { MessageKind.fromByte(it) != null }
        assertEquals(MessageKind.entries.size, defined.size)
        assertTrue(MessageKind.fromByte(0x12) == null)
        assertTrue(MessageKind.fromByte(0x00) == null)
    }

    @Test
    fun connectionRolesUseTheirWireBytes() {
        assertEquals(ConnectionRole.Control, ConnectionRole.fromByte(1))
        assertEquals(ConnectionRole.Video, ConnectionRole.fromByte(2))
        assertNull(ConnectionRole.fromByte(3))
    }

    @Test
    fun framesCompareByContent() {
        assertEquals(Frame(MessageKind.Pong, byteArrayOf(9)), Frame(MessageKind.Pong, byteArrayOf(9)))
        assertEquals(
            Frame(MessageKind.Pong, byteArrayOf(9)).hashCode(),
            Frame(MessageKind.Pong, byteArrayOf(9)).hashCode(),
        )
        assertTrue(Frame(MessageKind.Pong, byteArrayOf(9)) != Frame(MessageKind.Ping, byteArrayOf(9)))
    }

    @Test
    fun anOversizedPayloadIsRefusedByTheEncoder() {
        try {
            FrameEncoder.encode(MessageKind.VideoChunk, ByteArray(MAX_FRAME_LENGTH.toInt()))
            fail("expected the encoder to refuse a frame over the limit")
        } catch (expected: IllegalArgumentException) {
            assertTrue(expected.message!!.contains("frame limit"))
        }
    }

    private fun JsonObject.int(name: String): Int = text(name).toInt()

    private fun JsonObject.text(name: String): String = this[name]!!.jsonPrimitive.content
}
