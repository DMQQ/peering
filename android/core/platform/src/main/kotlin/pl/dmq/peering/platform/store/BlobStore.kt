package pl.dmq.peering.platform.store

import pl.dmq.peering.session.ports.StoredRead

/** Named byte blobs kept on the device. Implementations decide how the bytes are protected. */
interface BlobStore {
    /** The blob stored under [name], or null when there is none or it cannot be read. */
    fun get(name: String): ByteArray?

    /** Like [get], but tells an unreadable blob from an absent one. */
    fun read(name: String): StoredRead = get(name)?.let { StoredRead.Found(it) } ?: StoredRead.Absent

    /** Replaces the blob under [name]. False when the write did not persist. */
    fun put(name: String, value: ByteArray): Boolean
}
