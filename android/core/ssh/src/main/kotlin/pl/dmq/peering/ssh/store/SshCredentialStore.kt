package pl.dmq.peering.ssh.store

import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import pl.dmq.peering.session.ports.SecretStore
import pl.dmq.peering.ssh.model.SshCredential

/** One blob holding a map, so "does this host have a saved password" is not a Keystore decryption per row. */
class SshCredentialStore(secrets: SecretStore) {
    private val blob = JsonSecretBlob(
        secrets,
        KEY,
        MapSerializer(String.serializer(), SshCredential.serializer()),
        emptyMap(),
    )

    fun all(): Map<String, SshCredential> = blob.load()

    fun credential(hostId: String): SshCredential? = all()[hostId]

    fun hasCredential(hostId: String): Boolean = credential(hostId) != null

    /** The result matters: the caller tells the user "saved" or "you will be asked again" from it. */
    fun save(credential: SshCredential, hostId: String): Boolean = blob.save(all() + (hostId to credential))

    fun remove(hostId: String): Boolean {
        val current = all()
        return if (hostId in current) blob.save(current - hostId) else true
    }

    private companion object {
        const val KEY = "ssh.credentials"
    }
}
