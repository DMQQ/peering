package pl.dmq.peering.ssh.store

import kotlinx.serialization.KSerializer
import pl.dmq.peering.session.ports.SecretStore
import pl.dmq.peering.session.ports.StoredRead
import pl.dmq.peering.ssh.SshJson

/**
 * One value kept as JSON under one key of a [SecretStore], which on Android is sealed by a Keystore key. Each read is
 * a decryption, and the screens ask often, so the value is held after the first read. This process is the only writer.
 */
internal class JsonSecretBlob<T : Any>(
    private val secrets: SecretStore,
    private val key: String,
    private val serializer: KSerializer<T>,
    private val empty: T,
) {
    private var cached: T? = null

    /** A blob that is unreadable or will not decode answers [empty], and is left on disk for a build that can read it. */
    @Synchronized
    fun load(): T {
        cached?.let { return it }
        return when (val read = secrets.read(key)) {
            is StoredRead.Found -> decode(read.bytes).also { cached = it }
            StoredRead.Absent -> empty.also { cached = it }
            // A failure that may pass is not remembered, or one bad moment would hide the list until the app restarts.
            is StoredRead.Unreadable -> empty
        }
    }

    @Synchronized
    fun save(value: T): Boolean {
        val stored = secrets.put(key, SshJson.encodeToString(serializer, value).encodeToByteArray())
        if (stored) cached = value
        return stored
    }

    private fun decode(bytes: ByteArray): T =
        try {
            SshJson.decodeFromString(serializer, bytes.decodeToString())
        } catch (_: IllegalArgumentException) {
            empty
        }
}
