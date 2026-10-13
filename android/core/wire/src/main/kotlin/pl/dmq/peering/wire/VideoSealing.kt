package pl.dmq.peering.wire

import java.nio.ByteBuffer
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

enum class VideoDirection(val label: String) {
    ClientToHost("video client-to-host"),
    HostToClient("video host-to-client"),
}

const val VIDEO_SECRET_SIZE = 32
const val VIDEO_TOKEN_SIZE = 16
const val MAX_DATAGRAM_SIZE = 2048

private const val COUNTER_SIZE = 8
private const val TAG_SIZE = 16
private const val MIN_FORWARDED_DATAGRAM = COUNTER_SIZE + TAG_SIZE
private const val KEY_SIZE = 32
private const val CIPHER_NAME = "ChaCha20-Poly1305"
private const val KEY_ALGORITHM = "ChaCha20"
private val SALT = "pl.dmq.peering.video-datagram".toByteArray(Charsets.UTF_8)

sealed class SealException(message: String) : RuntimeException(message) {
    class Truncated(val have: Int, val need: Int) : SealException("datagram of $have bytes is shorter than $need")

    class Oversized(val size: Int) : SealException("datagram of $size bytes is larger than the protocol allows")

    data object AuthenticationFailed : SealException("datagram did not authenticate")

    data object MalformedPayload : SealException("authenticated datagram did not hold a frame")

    data object BadSecret : SealException("the video secret must be $VIDEO_SECRET_SIZE bytes")
}

/** HKDF-SHA256 with the video salt; the output is one block, so expand is a single HMAC. */
fun deriveVideoKey(secret: ByteArray, direction: VideoDirection): ByteArray {
    if (secret.size != VIDEO_SECRET_SIZE) throw SealException.BadSecret
    val pseudoRandomKey = hmacSha256(SALT, secret)
    val info = direction.label.toByteArray(Charsets.UTF_8)
    return hmacSha256(pseudoRandomKey, info + 1.toByte()).copyOf(KEY_SIZE)
}

/**
 * Seals outgoing messages. The counter is the nonce, so it must never repeat under one key: a sealer owns its counter
 * and one sealer per key.
 */
class VideoSealer(secret: ByteArray, direction: VideoDirection, private val token: ByteArray) {
    private val key = SecretKeySpec(deriveVideoKey(secret, direction), KEY_ALGORITHM)
    private var counter = 0L
    private var frameId = 0L

    init {
        require(token.size == VIDEO_TOKEN_SIZE) { "a video token is $VIDEO_TOKEN_SIZE bytes" }
    }

    /** A datagram of only the token: it registers this end's address with the relay and is forwarded nowhere. */
    fun bindDatagram(): ByteArray = token.copyOf()

    /** Cuts the message into datagram sized pieces and seals each. Returns nothing if it cannot be chunked. */
    fun seal(kind: MessageKind, payload: ByteArray): List<ByteArray> {
        frameId = (frameId + 1) and 0xFFFF_FFFFL
        return VideoChunkEncoder.encode(kind, payload, frameId, DATAGRAM_CHUNK_SIZE)
            .map { sealFrame(FrameEncoder.encode(it.kind, it.payload)) }
    }

    private fun sealFrame(plaintext: ByteArray): ByteArray {
        counter += 1
        val cipher = Cipher.getInstance(CIPHER_NAME).apply {
            init(Cipher.ENCRYPT_MODE, key, IvParameterSpec(nonce(counter)))
        }
        val boxed = cipher.doFinal(plaintext)
        return ByteBuffer.allocate(VIDEO_TOKEN_SIZE + COUNTER_SIZE + boxed.size)
            .put(token)
            .putLong(counter)
            .put(boxed)
            .array()
    }
}

/**
 * Opens datagrams the relay forwarded (counter, ciphertext, tag). One per lane: it owns the replay window and the
 * partial picture. A replayed datagram returns null; a forged one throws and leaves the window alone.
 */
class VideoOpener(secret: ByteArray, direction: VideoDirection) {
    private val key = SecretKeySpec(deriveVideoKey(secret, direction), KEY_ALGORITHM)
    private val window = ReplayWindow()
    private val chunks = VideoChunkReassembler()

    /** Returns a whole frame, or null for a replay or for a picture still missing pieces. */
    fun open(datagram: ByteArray): Frame? {
        if (datagram.size < MIN_FORWARDED_DATAGRAM) throw SealException.Truncated(datagram.size, MIN_FORWARDED_DATAGRAM)
        if (datagram.size > MAX_DATAGRAM_SIZE) throw SealException.Oversized(datagram.size)
        val counter = ByteBuffer.wrap(datagram, 0, COUNTER_SIZE).long
        if (!window.accepts(counter.toULong())) return null
        val plaintext = decrypt(counter, datagram.copyOfRange(COUNTER_SIZE, datagram.size))
        window.commit(counter.toULong())
        val frame = decodeFrame(plaintext)
        if (frame.kind != MessageKind.VideoChunk) return frame
        return try {
            chunks.ingest(frame)
        } catch (error: ChunkException) {
            throw SealException.MalformedPayload
        }
    }

    private fun decrypt(counter: Long, boxed: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(CIPHER_NAME).apply {
            init(Cipher.DECRYPT_MODE, key, IvParameterSpec(nonce(counter)))
        }
        return try {
            cipher.doFinal(boxed)
        } catch (error: AEADBadTagException) {
            throw SealException.AuthenticationFailed
        }
    }

    private fun decodeFrame(plaintext: ByteArray): Frame {
        val decoder = FrameDecoder()
        decoder.push(plaintext)
        return try {
            decoder.next() ?: throw SealException.MalformedPayload
        } catch (error: FramingException) {
            throw SealException.MalformedPayload
        }
    }
}

/** Four zero bytes, then the counter as big endian: twelve bytes, never reused under one key. */
private fun nonce(counter: Long): ByteArray =
    ByteBuffer.allocate(12).putInt(0).putLong(counter).array()

private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray =
    Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256"))
        doFinal(data)
    }
