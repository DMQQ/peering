package pl.dmq.peering.ssh.store

import kotlinx.serialization.builtins.ListSerializer
import pl.dmq.peering.session.ports.SecretStore
import pl.dmq.peering.ssh.model.SshHost

/** The saved servers as one blob. Not secret, but the Keystore-sealed store is the one the app already has. */
class SshHostStore(secrets: SecretStore) {
    private val blob = JsonSecretBlob(secrets, KEY, ListSerializer(SshHost.serializer()), emptyList())

    fun load(): List<SshHost> = blob.load()

    fun save(hosts: List<SshHost>): Boolean = blob.save(hosts)

    companion object {
        private const val KEY = "ssh.hosts"

        /** Most recently connected first, then never-connected in the order added. Sorted on read so the stored list keeps the order the user made. */
        fun ordered(hosts: List<SshHost>): List<SshHost> = hosts.sortedWith { left, right ->
            val l = left.lastConnectedAt
            val r = right.lastConnectedAt
            when {
                l != null && r != null -> r.compareTo(l)
                l != null -> -1
                r != null -> 1
                else -> left.createdAt.compareTo(right.createdAt)
            }
        }
    }
}
