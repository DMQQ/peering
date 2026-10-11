package pl.dmq.peering.wire

const val MAX_FRAME_LENGTH: Long = 16L * 1024 * 1024

enum class MessageKind(val byte: Int) {
    ConnectionRole(0x01),
    ClientHello(0x02),
    ServerHello(0x03),
    PairConfirm(0x04),
    PairResult(0x05),
    Command(0x06),
    Catalog(0x07),
    SetCaptureSource(0x08),
    VideoConfig(0x09),
    VideoFrame(0x0A),
    Ping(0x0B),
    Pong(0x0C),
    Error(0x0D),
    PairCommit(0x0E),
    PairReveal(0x0F),
    Notice(0x10),
    ClipboardContent(0x11),
    AudioConfig(0x13),
    AudioFrame(0x14),
    TerminalRequest(0x15),
    TerminalEvent(0x16),
    VideoChunk(0x17),
    VideoTransport(0x18),
    VideoKeyRequest(0x19),
    VideoKey(0x1A),
    DirectProbe(0x1B),
    TextFocus(0x1C),
    FieldState(0x1D),
    AgentRequest(0x1E),
    AgentEvent(0x1F),
    PreviewRequest(0x20),
    PreviewEvent(0x21),
    PointerReport(0x22);

    companion object {
        private val byByte: Map<Int, MessageKind> = entries.associateBy { it.byte }

        fun fromByte(byte: Int): MessageKind? = byByte[byte]
    }
}

/** Which stream a connection carries; the payload of the first frame on every connection. */
enum class ConnectionRole(val byte: Int) {
    Control(1),
    Video(2);

    companion object {
        fun fromByte(byte: Int): ConnectionRole? = entries.firstOrNull { it.byte == byte }
    }
}

class Frame(val kind: MessageKind, val payload: ByteArray) {
    override fun equals(other: Any?): Boolean =
        other is Frame && other.kind == kind && other.payload.contentEquals(payload)

    override fun hashCode(): Int = 31 * kind.hashCode() + payload.contentHashCode()

    override fun toString(): String = "Frame(kind=$kind, payload=${payload.size} bytes)"
}

sealed class FramingException(message: String) : RuntimeException(message)

data object ZeroLength : FramingException("frame with zero length")

class FrameTooLarge(val declared: Long) : FramingException("frame of $declared bytes exceeds the limit")

class UnknownKind(val byte: Int) : FramingException("unknown message kind $byte")

object FrameEncoder {
    fun encode(kind: MessageKind, payload: ByteArray): ByteArray {
        val length = payload.size + 1
        require(length <= MAX_FRAME_LENGTH) { "payload of ${payload.size} bytes exceeds the frame limit" }
        val out = ByteArray(5 + payload.size)
        out[0] = (length ushr 24).toByte()
        out[1] = (length ushr 16).toByte()
        out[2] = (length ushr 8).toByte()
        out[3] = length.toByte()
        out[4] = kind.byte.toByte()
        payload.copyInto(out, destinationOffset = 5)
        return out
    }
}

/**
 * Accumulates bytes from any read size and yields whole frames. The declared length is checked before the payload
 * is buffered, and a failing frame is left in place rather than consumed.
 */
class FrameDecoder {
    private var buffer = ByteArray(INITIAL_CAPACITY)
    private var start = 0
    private var end = 0

    val buffered: Int get() = end - start

    fun push(bytes: ByteArray) {
        makeRoom(bytes.size)
        bytes.copyInto(buffer, destinationOffset = end)
        end += bytes.size
    }

    fun next(): Frame? {
        if (buffered < LENGTH_PREFIX_SIZE) return null
        val length = readUnsignedInt(start)
        if (length == 0L) throw ZeroLength
        if (length > MAX_FRAME_LENGTH) throw FrameTooLarge(length)
        val total = LENGTH_PREFIX_SIZE + length.toInt()
        if (buffered < total) return null
        val rawKind = buffer[start + LENGTH_PREFIX_SIZE].toInt() and 0xFF
        val kind = MessageKind.fromByte(rawKind) ?: throw UnknownKind(rawKind)
        val payload = buffer.copyOfRange(start + LENGTH_PREFIX_SIZE + 1, start + total)
        start += total
        if (start == end) {
            start = 0
            end = 0
        }
        return Frame(kind, payload)
    }

    private fun readUnsignedInt(offset: Int): Long =
        (0 until LENGTH_PREFIX_SIZE).fold(0L) { value, index ->
            (value shl 8) or (buffer[offset + index].toLong() and 0xFF)
        }

    private fun makeRoom(incoming: Int) {
        if (end + incoming <= buffer.size) return
        val live = buffered
        val needed = live + incoming
        if (needed <= buffer.size) {
            buffer.copyInto(buffer, destinationOffset = 0, startIndex = start, endIndex = end)
        } else {
            val grown = ByteArray(maxOf(needed, buffer.size * 2))
            buffer.copyInto(grown, destinationOffset = 0, startIndex = start, endIndex = end)
            buffer = grown
        }
        start = 0
        end = live
    }

    private companion object {
        const val LENGTH_PREFIX_SIZE = 4
        const val INITIAL_CAPACITY = 4096
    }
}
