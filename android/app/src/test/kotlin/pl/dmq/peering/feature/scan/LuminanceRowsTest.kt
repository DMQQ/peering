package pl.dmq.peering.feature.scan

import org.junit.Assert.assertEquals
import org.junit.Test

class LuminanceRowsTest {
    @Test
    fun aTightPlaneIsCopiedUnchanged() {
        val plane = ByteArray(6) { it.toByte() }

        assertEquals(plane.toList(), compactLuminanceRows(plane, rowStride = 3, width = 3, height = 2).toList())
    }

    @Test
    fun aPlaneShorterThanItsRowsKeepsTheRowsItHas() {
        val plane = ByteArray(5) { (it + 1).toByte() }

        val compact = compactLuminanceRows(plane, rowStride = 4, width = 4, height = 2)

        assertEquals(listOf<Byte>(1, 2, 3, 4, 5, 0, 0, 0), compact.toList())
    }
}
