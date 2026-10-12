package pl.dmq.peering.platform.store

import pl.dmq.peering.session.ports.PinStore

private const val PINS_BLOB = "pl.dmq.peering.pins"

/**
 * The paired hosts and their keys. Memory and storage always agree: a write that does not persist puts the previous
 * state back before returning false, so a pairing never counts as done when the next launch would not know it.
 */
class PinStoreImpl(private val blobs: BlobStore) : PinStore {
    private val lock = Any()
    private val pins: MutableMap<String, ByteArray> = PinCodec.decode(blobs.get(PINS_BLOB)).toMutableMap()

    override fun pin(hostId: String): ByteArray? = synchronized(lock) { pins[hostId]?.copyOf() }

    override fun hostIds(): List<String> = synchronized(lock) { pins.keys.toList() }

    override fun record(hostId: String, key: ByteArray): Boolean = synchronized(lock) {
        val previous = pins.put(hostId, key.copyOf())
        if (persist()) return true
        restore(hostId, previous)
        false
    }

    override fun remove(hostId: String): Boolean = synchronized(lock) {
        val previous = pins.remove(hostId) ?: return true
        if (persist()) return true
        pins[hostId] = previous
        false
    }

    private fun persist(): Boolean = blobs.put(PINS_BLOB, PinCodec.encode(pins))

    private fun restore(hostId: String, previous: ByteArray?) {
        if (previous == null) pins.remove(hostId) else pins[hostId] = previous
    }
}
