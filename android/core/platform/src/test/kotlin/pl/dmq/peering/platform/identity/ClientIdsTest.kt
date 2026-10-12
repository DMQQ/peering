package pl.dmq.peering.platform.identity

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.session.ports.SecretStore
import pl.dmq.peering.session.ports.StoredRead

class ClientIdsTest {
    private class FakeSecrets(var result: StoredRead, var writable: Boolean = true) : SecretStore {
        var written: ByteArray? = null

        override fun get(key: String): ByteArray? = (result as? StoredRead.Found)?.bytes

        override fun read(key: String): StoredRead = result

        override fun put(key: String, value: ByteArray): Boolean {
            if (!writable) return false
            written = value
            return true
        }

        override fun remove(key: String): Boolean = true
    }

    @Test
    fun storedIdIsReused() {
        val secrets = FakeSecrets(StoredRead.Found("ABC".toByteArray()))

        assertEquals("ABC", ClientIds.resolve(secrets))
        assertNull(secrets.written)
    }

    @Test
    fun absentIdIsMintedAndStored() {
        val secrets = FakeSecrets(StoredRead.Absent)

        val id = ClientIds.resolve(secrets)

        assertEquals(id, secrets.written?.toString(Charsets.UTF_8))
    }

    @Test
    fun unreadableIdIsNeverOverwrittenWhenTheFailureMayPass() {
        val secrets = FakeSecrets(StoredRead.Unreadable(permanent = false))

        val id = ClientIds.resolve(secrets)

        assertNull(secrets.written)
        assertNotEquals("", id)
    }

    @Test
    fun permanentlyLostIdIsReplaced() {
        val secrets = FakeSecrets(StoredRead.Unreadable(permanent = true))

        val id = ClientIds.resolve(secrets)

        assertEquals(id, secrets.written?.toString(Charsets.UTF_8))
    }

    @Test
    fun failedStoreStillYieldsAnId() {
        val secrets = FakeSecrets(StoredRead.Absent, writable = false)

        assertNotEquals("", ClientIds.resolve(secrets))
    }
}
