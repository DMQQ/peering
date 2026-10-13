package pl.dmq.peering.feature.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream

class InputChunksTest {
    @Test
    fun splitsIntoFullPiecesAndAShorterLastOne() {
        val pieces = InputChunks(ByteArrayInputStream(ByteArray(10) { it.toByte() }), 4).asSequence().toList()
        assertEquals(listOf(4, 4, 2), pieces.map { it.size })
        assertEquals(listOf<Byte>(8, 9), pieces.last().toList())
    }

    @Test
    fun anEmptyInputHasNoPieces() {
        assertFalse(InputChunks(ByteArrayInputStream(ByteArray(0)), 4).hasNext())
    }

    @Test
    fun aSlowStreamStillFillsEachPiece() {
        val trickle = object : InputStream() {
            private var left = 6

            override fun read(): Int = if (left-- > 0) 1 else -1

            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (left <= 0) return -1
                buffer[offset] = 1
                left--
                return 1
            }
        }
        assertEquals(listOf(4, 2), InputChunks(trickle, 4).asSequence().map { it.size }.toList())
    }

    @Test(expected = IOException::class)
    fun aFailedReadSurfacesToTheCaller() {
        val broken = object : InputStream() {
            override fun read(): Int = throw IOException("gone")
        }
        InputChunks(broken, 4).hasNext()
    }
}
