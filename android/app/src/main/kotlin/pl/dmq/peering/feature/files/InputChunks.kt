package pl.dmq.peering.feature.files

import java.io.IOException
import java.io.InputStream

/** The bytes of [input] in pieces of at most [chunkBytes], read as they are asked for. A read failure surfaces as [IOException]. */
class InputChunks(private val input: InputStream, private val chunkBytes: Int) : Iterator<ByteArray> {
    private var ahead: ByteArray? = null

    override fun hasNext(): Boolean {
        if (ahead == null) ahead = readPiece()
        return ahead != null
    }

    override fun next(): ByteArray {
        val piece = ahead ?: readPiece() ?: throw NoSuchElementException()
        ahead = null
        return piece
    }

    private fun readPiece(): ByteArray? {
        val buffer = ByteArray(chunkBytes)
        var filled = 0
        while (filled < chunkBytes) {
            val count = input.read(buffer, filled, chunkBytes - filled)
            if (count < 0) break
            filled += count
        }
        return when (filled) {
            0 -> null
            chunkBytes -> buffer
            else -> buffer.copyOf(filled)
        }
    }
}
