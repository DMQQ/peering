package pl.dmq.peering.wire

import java.io.InputStream
import java.security.MessageDigest

/**
 * MD5 as a corruption check on file transfers, not as security: the channel is already authenticated and encrypted,
 * so this only catches a file that was written or read wrongly. Lowercase hex, as the other ends write it.
 */
class FileChecksum {
    private val digest = MessageDigest.getInstance("MD5")

    fun update(bytes: ByteArray) {
        digest.update(bytes)
    }

    fun update(bytes: ByteArray, count: Int) {
        digest.update(bytes, 0, count)
    }

    fun finalized(): String = digest.digest().toHex()

    companion object {
        private const val PIECE_BYTES = 1 shl 20

        fun of(bytes: ByteArray): String = FileChecksum().apply { update(bytes) }.finalized()

        /** Reads in pieces, so a large file is never held in memory. Stops after [limit] bytes when given. */
        fun of(input: InputStream, limit: Long = Long.MAX_VALUE): String {
            val checksum = FileChecksum()
            val buffer = ByteArray(PIECE_BYTES)
            var remaining = limit
            while (remaining > 0) {
                val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (read < 0) break
                checksum.update(buffer, read)
                remaining -= read
            }
            return checksum.finalized()
        }
    }
}
