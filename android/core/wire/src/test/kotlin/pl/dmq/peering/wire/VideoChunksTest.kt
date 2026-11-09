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
    fun anIndexBeyondItsCountAndItsParityIsRejected() {
        assertThrows(OutOfRange::class.java) {
            VideoChunkReassembler().ingest(chunk(MessageKind.VideoFrame.byte, 1, 6, 5))
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

    /** Eleven chunks of two bytes, the last holding one, so the first group is full and the second is the short last chunk alone. */
    private fun elevenChunks(): Pair<ByteArray, List<Frame>> {
        val data = ByteArray(21) { it.toByte() }
        val frames = VideoChunkEncoder.encodeWithParity(MessageKind.VideoFrame, data, 7, chunkSize = 2)
        assertEquals(13, frames.size)
        return data to frames
    }

    private fun feed(frames: List<Frame>): Frame? =
        VideoChunkReassembler().let { reassembler -> frames.fold<Frame, Frame?>(null) { done, frame -> reassembler.ingest(frame) ?: done } }

    @Test
    fun parityBodiesAreTheLengthThenTheXorOfTheGroup() {
        val data = ByteArray(10) { it.toByte() }
        val frames = VideoChunkEncoder.encodeWithParity(MessageKind.VideoFrame, data, 7, chunkSize = 4, group = 2)
        val kind = MessageKind.VideoFrame.byte.toByte()
        assertEquals(5, frames.size)
        assertEquals(
            byteArrayOf(kind, 0, 0, 0, 7, 0, 3, 0, 3, 0, 0, 0, 10, 4, 4, 4, 4).toList(),
            frames[3].payload.toList(),
        )
        assertEquals(
            byteArrayOf(kind, 0, 0, 0, 7, 0, 4, 0, 3, 0, 0, 0, 10, 8, 9, 0, 0).toList(),
            frames[4].payload.toList(),
        )
    }

    @Test
    fun anySingleLostChunkIsRebuiltFromItsGroupsParity() {
        val (data, frames) = elevenChunks()
        for (lost in 0 until 11) {
            val done = feed(frames.filterIndexed { index, _ -> index != lost })
            assertEquals("lost chunk $lost", Frame(MessageKind.VideoFrame, data).payload.toList(), done?.payload?.toList())
        }
    }

    @Test
    fun parityArrivingFirstStillRebuilds() {
        val (data, frames) = elevenChunks()
        val order = listOf(frames[11], frames[12]) + frames.take(11).filterIndexed { index, _ -> index != 4 }
        assertEquals(data.toList(), feed(order)?.payload?.toList())
    }

    @Test
    fun twoLostChunksInOneGroupAreNotRebuilt() {
        val (_, frames) = elevenChunks()
        assertNull(feed(frames.filterIndexed { index, _ -> index != 2 && index != 5 }))
    }

    @Test
    fun aWholeFrameIgnoresItsParity() {
        val (data, frames) = elevenChunks()
        assertEquals(data.toList(), feed(frames)?.payload?.toList())
    }

    @Test
    fun aPayloadThatFitsOnePieceCarriesNoParity() {
        assertEquals(1, VideoChunkEncoder.encodeWithParity(MessageKind.Ping, byteArrayOf(1, 2, 3), 1, 1024).size)
    }

    @Test
    fun aRealisticFrameSurvivesOneLossPerGroup() {
        val data = ByteArray(25_000) { (it * 31 % 251).toByte() }
        val frames = VideoChunkEncoder.encodeWithParity(MessageKind.VideoFrame, data, 9, DATAGRAM_CHUNK_SIZE)
        val count = (data.size + DATAGRAM_CHUNK_SIZE - 1) / DATAGRAM_CHUNK_SIZE
        assertEquals(count + (count + PARITY_GROUP_SIZE - 1) / PARITY_GROUP_SIZE, frames.size)
        val kept = frames.filterIndexed { index, _ -> index % PARITY_GROUP_SIZE != 3 || index >= count }
        assertEquals(data.toList(), feed(kept)?.payload?.toList())
    }

    @Test
    fun aCompletedFramesTrailingParityIsIgnored() {
        val (data, frames) = elevenChunks()
        val reassembler = VideoChunkReassembler()
        var done: Frame? = null
        for (frame in frames) done = reassembler.ingest(frame) ?: done
        assertEquals(data.toList(), done?.payload?.toList())
        // Ingesting the parity again must not restart the frame.
        assertNull(reassembler.ingest(frames[11]))
        assertNull(reassembler.ingest(frames[12]))
    }

    @Test
    fun aLatePriorFramesParityDoesNotWipeTheNextFramesProgress() {
        val (_, old) = elevenChunks()
        val newer = VideoChunkEncoder.encodeWithParity(MessageKind.VideoFrame, ByteArray(21) { it.toByte() }, 8, chunkSize = 2)
        val reassembler = VideoChunkReassembler()
        old.take(11).forEach { reassembler.ingest(it) }
        newer.take(10).forEach { reassembler.ingest(it) }
        // Frame 7 was completed by its data, so its parity arriving late must not disturb frame 8.
        reassembler.ingest(old[11])
        val rest = newer.drop(10).fold<Frame, Frame?>(null) { done, frame -> reassembler.ingest(frame) ?: done }
        assertEquals(ByteArray(21) { it.toByte() }.toList(), rest?.payload?.toList())
    }

    @Test
    fun anOversizedDataChunkNeverBreaksRecovery() {
        val (_, frames) = elevenChunks()
        val reassembler = VideoChunkReassembler()
        // Chunk 3 arrives far longer than the parity block: recovery of its group must not throw.
        val fat = frames[3].payload.copyOf(frames[3].payload.size + 40)
        reassembler.ingest(frames[0])
        reassembler.ingest(Frame(frames[3].kind, fat))
        reassembler.ingest(frames[11])
        frames.drop(4).take(6).forEach { reassembler.ingest(it) }
    }
}
