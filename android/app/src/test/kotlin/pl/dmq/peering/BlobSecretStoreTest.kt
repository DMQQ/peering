package pl.dmq.peering

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.platform.store.BlobStore
import pl.dmq.peering.session.ports.StoredRead

class BlobSecretStoreTest {
    private class FakeBlobs(var result: StoredRead) : BlobStore {
        override fun get(name: String): ByteArray? = (result as? StoredRead.Found)?.bytes

        override fun read(name: String): StoredRead = result

        override fun put(name: String, value: ByteArray): Boolean = true
    }

    @Test
    fun emptyBlobReadsAsAbsent() {
        assertEquals(StoredRead.Absent, BlobSecretStore(FakeBlobs(StoredRead.Found(ByteArray(0)))).read("k"))
    }

    @Test
    fun unreadableBlobStaysUnreadable() {
        val result = BlobSecretStore(FakeBlobs(StoredRead.Unreadable(permanent = false))).read("k")

        assertTrue(result is StoredRead.Unreadable && !result.permanent)
    }
}
