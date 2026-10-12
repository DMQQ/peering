package pl.dmq.peering.platform.store

import pl.dmq.peering.session.ports.PinStore
import pl.dmq.peering.session.ports.StoredRead

private const val PINS_BLOB = "pl.dmq.peering.pins"

/**
 * The paired hosts and their keys. Memory and storage always agree: a write that does not persist puts the previous
 * state back before returning false, so a pairing never counts as done when the next launch would not know it.
 *
 * A blob that exists but cannot be read is never overwritten while the failure may pass: reads are retried and writes
 * are refused. Only a permanent loss (the key is gone, the bytes are damaged) lets a new pairing replace it.
 */
class PinStoreImpl(private val blobs: BlobStore) : PinStore {
    private val lock = Any()
    private val pins: MutableMap<String, ByteArray> = mutableMapOf()
    private var loaded = false
    private var transientFailure = false
    private var failureNoticePending = false

    override fun pin(hostId: String): ByteArray? = synchronized(lock) {
        load()
        pins[hostId]?.copyOf()
    }

    override fun hostIds(): List<String> = synchronized(lock) {
        load()
        pins.keys.toList()
    }

    override fun record(hostId: String, key: ByteArray): Boolean = synchronized(lock) {
        load()
        if (transientFailure) return false
        val previous = pins.put(hostId, key.copyOf())
        if (persist()) return true
        restore(hostId, previous)
        false
    }

    override fun remove(hostId: String): Boolean = synchronized(lock) {
        load()
        if (transientFailure) return false
        val previous = pins.remove(hostId) ?: return true
        if (persist()) return true
        pins[hostId] = previous
        false
    }

    /** True once after a stored pin file turned out to be unreadable, so the UI can tell the user to pair again. */
    fun takeReadFailure(): Boolean = synchronized(lock) {
        load()
        failureNoticePending.also { failureNoticePending = false }
    }

    private fun load() {
        if (loaded) return
        when (val result = blobs.read(PINS_BLOB)) {
            StoredRead.Absent -> loaded = true
            is StoredRead.Found -> {
                val parsed = PinCodec.parse(result.bytes)
                if (parsed == null) {
                    failureNoticePending = true
                } else {
                    pins.putAll(parsed)
                }
                loaded = true
            }
            is StoredRead.Unreadable -> {
                if (!transientFailure) failureNoticePending = true
                transientFailure = !result.permanent
                loaded = result.permanent
            }
        }
        if (loaded) transientFailure = false
    }

    private fun persist(): Boolean = blobs.put(PINS_BLOB, PinCodec.encode(pins))

    private fun restore(hostId: String, previous: ByteArray?) {
        if (previous == null) pins.remove(hostId) else pins[hostId] = previous
    }
}
