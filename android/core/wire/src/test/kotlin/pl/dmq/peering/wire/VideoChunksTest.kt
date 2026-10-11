package pl.dmq.peering.wire

import java.nio.ByteBuffer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class VideoChunksTest {
    private val chunksVector: JsonObject = VectorFiles.load("wire.json").jsonObject.getValue("chunks").jsonObject

    private fun payload(length: Int = 2500): ByteArray = ByteArray(length) { (it % 251).toByte() }

    private fun decodeFrame(hex: String): Frame {
        val decoder = FrameDecoder()
        decoder.push(hex.hexToBytes())
        return requireNotNull(decoder.next())
    }

    private fun pieces(vector: JsonObject): List<Frame> =
        vector.getValue("pieces").jsonArray.map { decodeFrame(it.jsonPrimitive.content) }

    private fun vectorOrder(name: String): List<Int> =
        chunksVector.getValue("reassembleOrders").jsonObject.getValue(name).jsonArray.map { it.jsonPrimitive.content.toInt() }

    private fun chunk(kind: Int, frameId: Long, index: Int, count: Int, body: ByteArray = ByteArray(0)): Frame {
        val bytes = ByteBuffer.allocate(9 + body.size)
            .put(kind.toByte())
            .putInt(frameId.toInt())
            .putShort(index.toShort())
            .putShort(count.toShort())
            .put(body)
            .array()
        return Frame(MessageKind.VideoChunk, bytes)
    }

    @Test
    fun encodingMatchesTheSharedPieces() {
        val want = pieces(chunksVector)
        val got = VideoChunkEncoder.encode(MessageKind.VideoFrame, payload(), 7, DATAGRAM_CHUNK_SIZE)
        assertEquals(want, got)
    }

    @Test
    fun aPayloadThatFitsOnePieceIsReturnedAsItself() {
        val got = VideoChunkEncoder.encode(MessageKind.Ping, byteArrayOf(1, 2, 3), 1, DATAGRAM_CHUNK_SIZE)
        assertEquals(listOf(Frame(MessageKind.Ping, byteArrayOf(1, 2, 3))), got)
    }

    @Test
    fun aPayloadNeedingMoreThanSixtyFiveThousandPiecesEncodesToNothing() {
        assertEquals(emptyList<Frame>(), VideoChunkEncoder.encode(MessageKind.VideoFrame, payload(65536), 1, 1))
    }

    @Test
    fun exactlySixtyFiveThousandPiecesStillEncode() {
        assertEquals(65535, VideoChunkEncoder.encode(MessageKind.VideoFrame, payload(65535), 1, 1).size)
    }

    @Test
    fun reassemblesInOrderAndReversed() {
        val all = pieces(chunksVector)
        for (name in listOf("inOrder", "reversed")) {
            val reassembler = VideoChunkReassembler()
            var done: Frame? = null
            for (index in vectorOrder(name)) done = reassembler.ingest(all[index]) ?: done
            assertEquals(Frame(MessageKind.VideoFrame, payload()), done)
        }
    }

    @Test
    fun aLostPieceMeansNoPicture() {
        val all = pieces(chunksVector)
        val reassembler = VideoChunkReassembler()
        val delivered = chunksVector.getValue("lossCase").jsonObject.getValue("deliver").jsonArray
            .map { it.jsonPrimitive.content.toInt() }
        for (index in delivered) assertNull(reassembler.ingest(all[index]))
    }

    @Test
    fun aNewerFrameReplacesTheOneInProgress() {
        val reassembler = VideoChunkReassembler()
        assertNull(reassembler.ingest(pieces(chunksVector)[0]))
        val newer = pieces(chunksVector.getValue("newerFrame").jsonObject)
        var done: Frame? = null
        for (piece in newer) done = reassembler.ingest(piece) ?: done
        assertEquals(Frame(MessageKind.VideoFrame, payload(1500)), done)
    }

    @Test
    fun aPieceWithAContradictingKindIsIgnored() {
        val reassembler = VideoChunkReassembler()
        val all = pieces(chunksVector)
        assertNull(reassembler.ingest(all[0]))
        val impostor = VideoChunkEncoder.encode(MessageKind.Command, payload(), 7, DATAGRAM_CHUNK_SIZE)[1]
        assertNull(reassembler.ingest(impostor))
        assertNull(reassembler.ingest(all[2]))
        assertEquals(Frame(MessageKind.VideoFrame, payload()), reassembler.ingest(all[1]))
    }

    @Test
    fun aPieceWithAContradictingCountIsIgnored() {
        val reassembler = VideoChunkReassembler()
        val all = pieces(chunksVector)
        assertNull(reassembler.ingest(all[0]))
        val shortPicture = VideoChunkEncoder.encode(MessageKind.VideoFrame, payload(1500), 7, DATAGRAM_CHUNK_SIZE)[1]
        assertNull(reassembler.ingest(shortPicture))
        assertNull(reassembler.ingest(all[2]))
        assertEquals(Frame(MessageKind.VideoFrame, payload()), reassembler.ingest(all[1]))
    }

    @Test
    fun aTruncatedHeaderIsRejected() {
        val error = assertThrows(TruncatedHeader::class.java) {
            VideoChunkReassembler().ingest(Frame(MessageKind.VideoChunk, ByteArray(3)))
        }
        assertEquals(3, error.have)
    }

    @Test
    fun aChunkCarryingAChunkIsRejected() {
        assertThrows(Nested::class.java) {
            VideoChunkReassembler().ingest(chunk(MessageKind.VideoChunk.byte, 1, 0, 1))
        }
    }

    @Test
    fun anUnknownInnerKindIsRejected() {
        val error = assertThrows(UnknownInnerKind::class.java) {
            VideoChunkReassembler().ingest(chunk(0xEE, 1, 0, 1))
        }
        assertEquals(0xEE, error.byte)
    }

    @Test
    fun anIndexOutsideItsCountIsRejected() {
        assertThrows(OutOfRange::class.java) {
            VideoChunkReassembler().ingest(chunk(MessageKind.VideoFrame.byte, 1, 5, 5))
        }
    }

    @Test
    fun aZeroCountIsRejected() {
        assertThrows(OutOfRange::class.java) {
            VideoChunkReassembler().ingest(chunk(MessageKind.VideoFrame.byte, 1, 0, 0))
        }
    }

    @Test
    fun aBodyLargerThanAControlChunkIsRejected() {
        assertThrows(Oversized::class.java) {
            VideoChunkReassembler().ingest(chunk(MessageKind.VideoFrame.byte, 1, 0, 1, ByteArray(CONTROL_CHUNK_SIZE + 1)))
        }
    }

    @Test
    fun aPictureOverTheCapIsDroppedWhilePictureAtTheCapIsKept() {
        val pieces = VideoChunkEncoder.encode(MessageKind.VideoFrame, payload(40), 1, 8)
        val overCap = VideoChunkReassembler(maxReassembled = 39)
        assertNull(pieces.fold<Frame, Frame?>(null) { _, piece -> overCap.ingest(piece) })

        val atCap = VideoChunkReassembler(maxReassembled = 40)
        assertEquals(Frame(MessageKind.VideoFrame, payload(40)), pieces.fold<Frame, Frame?>(null) { _, piece -> atCap.ingest(piece) })
    }
}
