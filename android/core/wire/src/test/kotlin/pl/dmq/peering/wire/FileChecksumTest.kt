package pl.dmq.peering.wire

import java.io.ByteArrayInputStream
import org.junit.Test
import org.junit.Assert.assertEquals

class FileChecksumTest {
    @Test
    fun emptyInputHashesToTheKnownDigest() {
        assertEquals("d41d8cd98f00b204e9800998ecf8427e", FileChecksum.of(ByteArray(0)))
    }

    @Test
    fun hexIsLowercase() {
        assertEquals("5289df737df57326fcdd22597afb1fac", FileChecksum.of(byteArrayOf(1, 2, 3)))
    }

    @Test
    fun streamedPiecesHashLikeTheWholeFile() {
        val bytes = ByteArray(3_000_000) { (it * 31).toByte() }
        assertEquals(FileChecksum.of(bytes), FileChecksum.of(ByteArrayInputStream(bytes)))
    }

    @Test
    fun aLimitStopsTheHashThere() {
        val bytes = byteArrayOf(1, 2, 3, 4, 5)
        assertEquals(FileChecksum.of(byteArrayOf(1, 2, 3)), FileChecksum.of(ByteArrayInputStream(bytes), limit = 3))
    }
}
