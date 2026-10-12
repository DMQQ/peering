package pl.dmq.peering.session.ports

/** Small secrets kept by the platform, such as relay tokens and video keys. */
interface SecretStore {
    /** The value under [key], or null when nothing is stored or it cannot be read. */
    fun get(key: String): ByteArray?

    /** Like [get], but tells an unreadable value from an absent one. */
    fun read(key: String): StoredRead = get(key)?.let { StoredRead.Found(it) } ?: StoredRead.Absent

    /** Stores [value] under [key]. False when the write did not persist. */
    fun put(key: String, value: ByteArray): Boolean

    /** Deletes [key]. False when the delete did not persist. */
    fun remove(key: String): Boolean
}
