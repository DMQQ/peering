package pl.dmq.peering.widget

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkNonceTest {
    private val directory = Files.createTempDirectory("nonce").toFile()

    @Test
    fun theNonceIsMadeOnceAndReadBackAfterwards() {
        val first = LinkNonce.load(directory)
        val second = LinkNonce.load(directory) { error("must not make another") }
        assertEquals(first, second)
        assertEquals(64, first.length)
    }

    @Test
    fun twoInstallsGetDifferentNonces() {
        val other = Files.createTempDirectory("nonce").toFile()
        assertNotEquals(LinkNonce.load(directory), LinkNonce.load(other))
    }

    @Test
    fun onlyTheInstallsOwnNonceIsAccepted() {
        val nonce = LinkNonce.load(directory)
        assertTrue(LinkNonce.accepts(nonce, nonce))
        assertFalse(LinkNonce.accepts(nonce, null))
        assertFalse(LinkNonce.accepts(nonce, ""))
        assertFalse(LinkNonce.accepts(nonce, nonce.reversed()))
        assertFalse(LinkNonce.accepts(nonce, nonce + "0"))
    }
}
