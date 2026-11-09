package pl.dmq.peering.wire

import java.nio.ByteBuffer

const val CONTROL_CHUNK_SIZE = 16 * 1024
const val DATAGRAM_CHUNK_SIZE = 1024
const val MAX_REASSEMBLED_BYTES = 4 * 1024 * 1024

/** Data chunks covered by one parity chunk on the datagram lane: one lost chunk in ten is rebuilt, for ten percent more bytes. */
const val PARITY_GROUP_SIZE = 10

private const val CHUNK_HEADER_SIZE = 9
private const val PARITY_LENGTH_SIZE = 4
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

    /**
     * Like [encode], then one parity chunk per [group] data chunks, numbered after the data ones. A parity body is the
     * payload's length followed by the XOR of its group's chunk bodies, each zero padded to [chunkSize]. A payload that fits
     * one piece goes out as itself and is not protected.
     */
    fun encodeWithParity(kind: MessageKind, payload: ByteArray, frameId: Long, chunkSize: Int, group: Int = PARITY_GROUP_SIZE): List<Frame> {
        val data = encode(kind, payload, frameId, chunkSize)
        if (payload.size <= chunkSize || data.isEmpty()) return data
        val count = data.size
        val groups = (count + group - 1) / group
        if (count + groups > MAX_CHUNK_COUNT) return data
        val parity = (0 until groups).map { g ->
            val xor = ByteArray(chunkSize)
            for (index in g * group until minOf((g + 1) * group, count)) {
                val start = index * chunkSize
                for (offset in 0 until minOf(chunkSize, payload.size - start)) xor[offset] = (xor[offset].toInt() xor payload[start + offset].toInt()).toByte()
            }
            val body = ByteBuffer.allocate(CHUNK_HEADER_SIZE + PARITY_LENGTH_SIZE + chunkSize)
                .put(kind.byte.toByte()).putInt(frameId.toInt()).putShort((count + g).toShort()).putShort(count.toShort())
                .putInt(payload.size).put(xor).array()
            Frame(MessageKind.VideoChunk, body)
        }
        return data + parity
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

    /** The frame last handed out. Its trailing parity chunks are still on the wire and would each open an empty assembly. */
    private var completedFrameId: Long? = null

    /** Returns the whole inner frame once its last missing piece arrives, otherwise null. */
    fun ingest(frame: Frame): Frame? {
        val chunk = ChunkHeader.parse(frame.payload)
        if (chunk.frameId == completedFrameId) return null
        val current = assembly?.takeIf { it.frameId == chunk.frameId }
            ?: Assembly(chunk.frameId, chunk.kind, chunk.count).also { assembly = it }
        if (current.kind != chunk.kind || current.count != chunk.count) return null
        val group = if (chunk.index >= chunk.count) {
            current.keepParity(chunk.index - chunk.count, chunk.body)
            chunk.index - chunk.count
        } else {
            if (current.parts.putIfAbsent(chunk.index, chunk.body) == null) current.bufferedBytes += chunk.body.size
            chunk.index / PARITY_GROUP_SIZE
        }
        if (current.bufferedBytes > maxReassembled) {
            assembly = null
            return null
        }
        if (current.parts.size != current.count) current.recover(group)
        if (current.parts.size != current.count) return null
        assembly = null
        completedFrameId = current.frameId
        return Frame(current.kind, current.join())
    }

    private class Assembly(val frameId: Long, val kind: MessageKind, val count: Int) {
        val parts = HashMap<Int, ByteArray>()
        private val parities = HashMap<Int, ByteArray>()
        private var totalLength = -1
        var bufferedBytes = 0

        fun keepParity(group: Int, body: ByteArray) {
            if (body.size <= PARITY_LENGTH_SIZE) return
            totalLength = ByteBuffer.wrap(body).getInt()
            parities[group] = body.copyOfRange(PARITY_LENGTH_SIZE, body.size)
        }

        /**
         * Rebuilds the one missing chunk of [group] once its parity has arrived, which is the only group the chunk just
         * ingested can have changed. Two missing in a group are left, as before parity existed.
         */
        fun recover(group: Int) {
            val xor = parities[group] ?: return
            if (totalLength < 0) return
            val first = group * PARITY_GROUP_SIZE
            val last = minOf(first + PARITY_GROUP_SIZE, count)
            var lost = -1
            for (index in first until last) {
                if (index in parts) continue
                if (lost >= 0) return
                lost = index
            }
            if (lost < 0) return
            val rebuilt = xor.copyOf()
            for (present in first until last) {
                if (present == lost) continue
                val part = parts.getValue(present)
                for (i in 0 until minOf(part.size, rebuilt.size)) rebuilt[i] = (rebuilt[i].toInt() xor part[i].toInt()).toByte()
            }
            val length = if (lost == count - 1) totalLength - (count - 1) * xor.size else xor.size
            if (length < 0 || length > rebuilt.size) return
            val chunk = rebuilt.copyOf(length)
            parts[lost] = chunk
            bufferedBytes += chunk.size
        }

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
            if (count == 0 || index >= count + (count + PARITY_GROUP_SIZE - 1) / PARITY_GROUP_SIZE) throw OutOfRange(index, count)
            val body = payload.copyOfRange(CHUNK_HEADER_SIZE, payload.size)
            if (body.size > CONTROL_CHUNK_SIZE) throw Oversized(body.size)
            return ChunkHeader(frameId, kind, index, count, body)
        }
    }
}
