package pl.dmq.peering.wire

import java.nio.ByteBuffer

const val CONTROL_CHUNK_SIZE = 16 * 1024
const val DATAGRAM_CHUNK_SIZE = 1024
const val MAX_REASSEMBLED_BYTES = 4 * 1024 * 1024

private const val CHUNK_HEADER_SIZE = 9
private const val MAX_CHUNK_COUNT = 0xFFFF
private const val MAX_FRAME_ID = 0xFFFF_FFFFL

sealed class ChunkException(message: String) : RuntimeException(message)

class TruncatedHeader(val have: Int) : ChunkException("chunk header truncated: have $have bytes")

class OutOfRange(val index: Int, val count: Int) : ChunkException("chunk index $index out of range for count $count")

data object Nested : ChunkException("a chunk may not carry a chunk")

class UnknownInnerKind(val byte: Int) : ChunkException("unknown inner message kind $byte")

class Oversized(val size: Int) : ChunkException("chunk body of $size bytes is too large")

object VideoChunkEncoder {
    /** A payload that fits one piece is returned as itself; more than 65535 pieces returns nothing. */
    fun encode(kind: MessageKind, payload: ByteArray, frameId: Long, chunkSize: Int): List<Frame> {
        require(chunkSize > 0) { "chunk size must be positive" }
        require(frameId in 0..MAX_FRAME_ID) { "frame id $frameId does not fit in 32 bits" }
        if (payload.size <= chunkSize) return listOf(Frame(kind, payload))
        val count = (payload.size + chunkSize - 1) / chunkSize
        if (count > MAX_CHUNK_COUNT) return emptyList()
        return (0 until count).map { index ->
            val start = index * chunkSize
            val part = payload.copyOfRange(start, minOf(start + chunkSize, payload.size))
            Frame(MessageKind.VideoChunk, chunkBody(kind, frameId, index, count, part))
        }
    }

    private fun chunkBody(kind: MessageKind, frameId: Long, index: Int, count: Int, part: ByteArray): ByteArray =
        ByteBuffer.allocate(CHUNK_HEADER_SIZE + part.size)
            .put(kind.byte.toByte())
            .putInt(frameId.toInt())
            .putShort(index.toShort())
            .putShort(count.toShort())
            .put(part)
            .array()
}

/**
 * Puts chunked pictures back together. One per lane: two lanes number their chunks independently, so sharing one
 * would read the other lane's chunks as a newer picture.
 */
class VideoChunkReassembler(private val maxReassembled: Int = MAX_REASSEMBLED_BYTES) {
    private var assembly: Assembly? = null

    /** Returns the whole inner frame once its last missing piece arrives, otherwise null. */
    fun ingest(frame: Frame): Frame? {
        val chunk = ChunkHeader.parse(frame.payload)
        val current = assembly?.takeIf { it.frameId == chunk.frameId }
            ?: Assembly(chunk.frameId, chunk.kind, chunk.count).also { assembly = it }
        if (current.kind != chunk.kind || current.count != chunk.count) return null
        if (current.parts.putIfAbsent(chunk.index, chunk.body) == null) current.bufferedBytes += chunk.body.size
        if (current.bufferedBytes > maxReassembled) {
            assembly = null
            return null
        }
        if (current.parts.size != current.count) return null
        assembly = null
        return Frame(current.kind, current.join())
    }

    private class Assembly(val frameId: Long, val kind: MessageKind, val count: Int) {
        val parts = HashMap<Int, ByteArray>()
        var bufferedBytes = 0

        fun join(): ByteArray {
            val joined = ByteArray(bufferedBytes)
            var offset = 0
            for (index in 0 until count) {
                val part = parts.getValue(index)
                part.copyInto(joined, offset)
                offset += part.size
            }
            return joined
        }
    }
}

private class ChunkHeader(val frameId: Long, val kind: MessageKind, val index: Int, val count: Int, val body: ByteArray) {
    companion object {
        fun parse(payload: ByteArray): ChunkHeader {
            if (payload.size < CHUNK_HEADER_SIZE) throw TruncatedHeader(payload.size)
            val buffer = ByteBuffer.wrap(payload)
            val kindByte = buffer.get().toInt() and 0xFF
            if (kindByte == MessageKind.VideoChunk.byte) throw Nested
            val kind = MessageKind.fromByte(kindByte) ?: throw UnknownInnerKind(kindByte)
            val frameId = buffer.getInt().toLong() and 0xFFFF_FFFFL
            val index = buffer.getShort().toInt() and 0xFFFF
            val count = buffer.getShort().toInt() and 0xFFFF
            if (count == 0 || index >= count) throw OutOfRange(index, count)
            val body = payload.copyOfRange(CHUNK_HEADER_SIZE, payload.size)
            if (body.size > CONTROL_CHUNK_SIZE) throw Oversized(body.size)
            return ChunkHeader(frameId, kind, index, count, body)
        }
    }
}
