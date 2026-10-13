package pl.dmq.peering.wire

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class AnnexBTest {
    private fun bytes(vararg values: Int): ByteArray = ByteArray(values.size) { values[it].toByte() }

    private fun assertBuffers(expected: List<ByteArray>, actual: List<ByteArray>) =
        assertEquals(expected.map { it.toList() }, actual.map { it.toList() })

    @Test
    fun lengthPrefixesBecomeStartCodes() {
        val avcc = bytes(0, 0, 0, 3, 1, 2, 3, 0, 0, 0, 1, 9)
        assertArrayEquals(bytes(0, 0, 0, 1, 1, 2, 3, 0, 0, 0, 1, 9), avccToAnnexB(avcc))
    }

    @Test
    fun theInputIsNotChanged() {
        val avcc = bytes(0, 0, 0, 1, 7)
        avccToAnnexB(avcc)
        assertArrayEquals(bytes(0, 0, 0, 1, 7), avcc)
    }

    @Test
    fun anEmptyFrameConvertsToNothing() {
        assertArrayEquals(ByteArray(0), avccToAnnexB(ByteArray(0)))
    }

    @Test
    fun aLengthRunningPastTheFrameIsRejected() {
        assertThrows(AnnexBException::class.java) { avccToAnnexB(bytes(0, 0, 0, 9, 1, 2)) }
    }

    @Test
    fun aLengthOfMaximumSizeIsRejected() {
        assertThrows(AnnexBException::class.java) { avccToAnnexB(bytes(0xFF, 0xFF, 0xFF, 0xFF, 1)) }
    }

    @Test
    fun aTruncatedLengthPrefixIsRejected() {
        assertThrows(AnnexBException::class.java) { avccToAnnexB(bytes(0, 0, 0, 1, 5, 0, 0)) }
    }

    @Test
    fun h264ConfigIsSpsThenPpsEachWithAStartCode() {
        val config = csdFor("h264", listOf(bytes(0x67, 1), bytes(0x68, 2)))
        assertBuffers(listOf(bytes(0, 0, 0, 1, 0x67, 1), bytes(0, 0, 0, 1, 0x68, 2)), config)
    }

    @Test
    fun hevcConfigIsOneBufferOfVpsSpsAndPpsWithStartCodes() {
        val config = csdFor("hevc", listOf(bytes(0x40, 1), bytes(0x42, 1), bytes(0x44, 1)))
        assertBuffers(listOf(bytes(0, 0, 0, 1, 0x40, 1, 0, 0, 0, 1, 0x42, 1, 0, 0, 0, 1, 0x44, 1)), config)
    }

    @Test
    fun codecConfigPrefixesEachParameterSet() {
        assertBuffers(listOf(bytes(0, 0, 0, 1, 3), bytes(0, 0, 0, 1, 4)), codecConfig(listOf(bytes(3), bytes(4))))
    }

    @Test
    fun aWrongNumberOfParameterSetsIsRejected() {
        assertThrows(AnnexBException::class.java) { csdFor("h264", listOf(bytes(0x67, 1))) }
        assertThrows(AnnexBException::class.java) { csdFor("hevc", listOf(bytes(0x42, 1), bytes(0x44, 1))) }
    }

    @Test
    fun anUnknownCodecIsRejected() {
        assertThrows(AnnexBException::class.java) { csdFor("vp9", listOf(bytes(1))) }
    }
}
