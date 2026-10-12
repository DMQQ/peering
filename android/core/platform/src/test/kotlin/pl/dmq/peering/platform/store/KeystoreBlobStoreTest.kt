package pl.dmq.peering.platform.store

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KeystoreBlobStoreTest {
    private val directory: File = Files.createTempDirectory("blobs").toFile()

    @Test
    fun concurrentPutsOfOneNameNeverPublishAMix() {
        val store = KeystoreBlobStore(directory) { it }
        val values = (1..8).map { fill -> ByteArray(256 * 1024) { fill.toByte() } }
        val pool = Executors.newFixedThreadPool(values.size)
        val start = CountDownLatch(1)
        val results = values.map { value ->
            pool.submit<Boolean> {
                start.await()
                (1..10).all { store.put("blob", value) }
            }
        }
        start.countDown()
        assertTrue(results.all { it.get(30, TimeUnit.SECONDS) })
        pool.shutdown()

        val published = File(directory, "blob").readBytes()
        assertTrue(values.any { it.contentEquals(published) })
        assertEquals(listOf("blob"), directory.list()!!.toList())
    }

    @Test
    fun aFailedPutLeavesNoTemporaryFileAndKeepsThePreviousBlob() {
        File(directory, "blob").writeBytes(byteArrayOf(7))
        val store = KeystoreBlobStore(directory) { throw java.security.GeneralSecurityException("no key") }

        assertFalse(store.put("blob", byteArrayOf(1)))

        assertEquals(listOf("blob"), directory.list()!!.toList())
        assertEquals(7.toByte(), File(directory, "blob").readBytes().single())
    }
}
