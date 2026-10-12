package pl.dmq.peering

import pl.dmq.peering.platform.store.BlobStore
import pl.dmq.peering.session.ports.SecretStore

// BlobStore has no delete, so a removed secret is an empty blob, which reads back as absent.
class BlobSecretStore(private val blobs: BlobStore) : SecretStore {
    override fun get(key: String): ByteArray? = blobs.get(key)?.takeIf { it.isNotEmpty() }

    override fun put(key: String, value: ByteArray): Boolean = blobs.put(key, value)

    override fun remove(key: String): Boolean = blobs.put(key, ByteArray(0))
}
