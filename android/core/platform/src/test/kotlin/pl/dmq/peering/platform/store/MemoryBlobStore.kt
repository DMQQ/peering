package pl.dmq.peering.platform.store

class MemoryBlobStore : BlobStore {
    val blobs: MutableMap<String, ByteArray> = mutableMapOf()
    var failWrites: Boolean = false

    override fun get(name: String): ByteArray? = blobs[name]?.copyOf()

    override fun put(name: String, value: ByteArray): Boolean {
        if (failWrites) return false
        blobs[name] = value.copyOf()
        return true
    }
}
