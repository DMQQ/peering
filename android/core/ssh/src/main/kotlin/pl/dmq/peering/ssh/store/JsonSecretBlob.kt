package pl.dmq.peering.ssh.store

import kotlinx.serialization.KSerializer
import pl.dmq.peering.session.ports.SecretStore
import pl.dmq.peering.session.ports.StoredRead
import pl.dmq.peering.ssh.SshJson

/** One value kept as JSON under one key of a [SecretStore], which on Android is sealed by a Keystore key. */
internal class JsonSecretBlob<T>(
    private val secrets: SecretStore,
    private val key: String,
    private val serializer: KSerializer<T>,
    private val empty: T,
) {
    /** A blob that is unreadable or will not decode answers [empty], and is left on disk for a build that can read it. */
    fun load(): T {
        val found = secrets.read(key) as? StoredRead.Found ?: return empty
        return try {
            SshJson.decodeFromString(serializer, found.bytes.decodeToString())
        } catch (_: IllegalArgumentException) {
            empty
        }
    }

    fun save(value: T): Boolean = secrets.put(key, SshJson.encodeToString(serializer, value).encodeToByteArray())

    fun clear(): Boolean = secrets.remove(key)
}
