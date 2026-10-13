package pl.dmq.peering.platform.identity

import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class IdentityMathTest {
    private fun newPublicKey(): ECPublicKey {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        return generator.generateKeyPair().public as ECPublicKey
    }

    private fun fixed32(value: BigInteger): ByteArray {
        val raw = value.toByteArray()
        val magnitude = if (raw.size > 32) raw.copyOfRange(raw.size - 32, raw.size) else raw
        return ByteArray(32).also { magnitude.copyInto(it, 32 - magnitude.size) }
    }

    @Test
    fun uncompressedPointIsPrefixThenBothCoordinates() {
        val key = newPublicKey()
        val point = uncompressedPoint(key)

        assertEquals(65, point.size)
        assertEquals(0x04.toByte(), point[0])
        assertArrayEquals(fixed32(key.w.affineX), point.copyOfRange(1, 33))
        assertArrayEquals(fixed32(key.w.affineY), point.copyOfRange(33, 65))
    }

    @Test
    fun uncompressedPointKeepsLeadingZeroCoordinatesAtFullWidth() {
        val key = generateSequence { newPublicKey() }
            .first { it.w.affineX.bitLength() <= 240 || it.w.affineY.bitLength() <= 240 }

        val point = uncompressedPoint(key)

        assertEquals(65, point.size)
        assertArrayEquals(fixed32(key.w.affineX), point.copyOfRange(1, 33))
        assertArrayEquals(fixed32(key.w.affineY), point.copyOfRange(33, 65))
    }

    @Test
    fun uncompressedPointIsStableAcrossCalls() {
        val key = newPublicKey()
        assertArrayEquals(uncompressedPoint(key), uncompressedPoint(key))
    }

    @Test
    fun deviceNameKeepsPlainNames() {
        assertEquals("Pixel 9 Pro", deviceName("Pixel 9 Pro"))
    }

    @Test
    fun deviceNameRemovesCharactersThatBreakTheDistinguishedName() {
        assertEquals("Tom Phone", deviceName("Tom, Phone=\"<>;\\"))
    }

    @Test
    fun deviceNameCollapsesBlankRuns() {
        assertEquals("Work phone", deviceName("   Work \t   phone  \n"))
    }

    @Test
    fun deviceNameFallsBackWhenNothingRemains() {
        assertEquals("Android device", deviceName(null))
        assertEquals("Android device", deviceName(" ,=, "))
    }

    @Test
    fun deviceNameIsCappedAtSixtyFourCharacters() {
        assertEquals(64, deviceName("a".repeat(200)).length)
    }
}
