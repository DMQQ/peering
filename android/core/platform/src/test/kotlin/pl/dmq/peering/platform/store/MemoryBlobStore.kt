package pl.dmq.peering.platform.store

import pl.dmq.peering.session.ports.StoredRead

class MemoryBlobStore : BlobStore {
    val blobs: MutableMap<String, ByteArray> = mutableMapOf()
    var failWrites: Boolean = false
    var unreadable: StoredRead.Unreadable? = null

    override fun get(name: String): ByteArray? = (read(name) as? StoredRead.Found)?.bytes

    override fun read(name: String): StoredRead {
        unreadable?.let { return it }
        return blobs[name]?.let { StoredRead.Found(it.copyOf()) } ?: StoredRead.Absent
    }

    override fun put(name: String, value: ByteArray): Boolean {
        if (failWrites) return false
        blobs[name] = value.copyOf()
        return true
    }
}
