package pl.dmq.peering.platform.net

import java.security.cert.CertificateException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PinningTrustManagerTest {
    @get:Rule
    val folder = TemporaryFolder()

    @Test
    fun firstPairingAcceptsAnyKeyAndRecordsIt() {
        val peer = PeerCredentials.generate(folder.root, "first")
        val trust = PinningTrustManager(pin = null, firstPairing = true)

        trust.checkServerTrusted(peer.certificateChain().toTypedArray(), "ECDHE")

        assertArrayEquals(peer.point, trust.observedKey())
    }

    @Test
    fun nothingIsRecordedBeforeAnyCheck() {
        assertNull(PinningTrustManager(pin = null, firstPairing = true).observedKey())
    }

    @Test
    fun matchingPinAccepts() {
        val peer = PeerCredentials.generate(folder.root, "pinned")
        val trust = PinningTrustManager(pin = peer.point)

        trust.checkServerTrusted(peer.certificateChain().toTypedArray(), "ECDHE")

        assertArrayEquals(peer.point, trust.observedKey())
    }

    @Test
    fun mismatchedPinIsRefusedAndTheKeyStillRecorded() {
        val pinned = PeerCredentials.generate(folder.root, "old")
        val stranger = PeerCredentials.generate(folder.root, "new")
        val trust = PinningTrustManager(pin = pinned.point)

        assertThrows(CertificateException::class.java) {
            trust.checkServerTrusted(stranger.certificateChain().toTypedArray(), "ECDHE")
        }
        assertArrayEquals(stranger.point, trust.observedKey())
    }

    @Test
    fun emptyChainIsRefused() {
        val trust = PinningTrustManager(pin = null, firstPairing = true)

        assertThrows(CertificateException::class.java) {
            trust.checkServerTrusted(emptyArray(), "ECDHE")
        }
    }

    @Test
    fun pinComparisonAcceptsOnlyTheSameBytes() {
        val key = ByteArray(65) { it.toByte() }
        assertTrue(pinAccepts(null, key))
        assertTrue(pinAccepts(key, key.copyOf()))
        assertFalse(pinAccepts(key, key.copyOf().also { it[64] = 0 }))
    }
}
