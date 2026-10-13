package pl.dmq.peering.ssh.model

import kotlinx.serialization.Serializable

/**
 * A machine the user has saved. Nothing secret is here: the password or key is an [SshCredential] and the lock
 * passcode a hash, each in its own store. Every field has a default so a list saved by an older build still decodes.
 */
@Serializable
data class SshHost(
    val id: String,
    val name: String = "",
    val hostname: String,
    val port: Int = SshEndpoint.DEFAULT_PORT,
    val username: String,
    val createdAt: Long = 0,
    val lastConnectedAt: Long? = null,
    val lock: SshHostLock = SshHostLock.OFF,
    /** Intent only: whether a forward is up is runtime state. */
    val forwards: List<SshPortForward> = emptyList(),
) {
    val endpoint: SshEndpoint get() = SshEndpoint(hostname, port)

    val displayName: String get() = name.ifEmpty { hostname }

    /** `user@host`, with the port only when it is not the default. */
    val detail: String get() = "$username@${endpoint.display}"
}
