package pl.dmq.peering.ssh.hostkey

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import pl.dmq.peering.session.ports.SecretStore
import pl.dmq.peering.ssh.model.SshEndpoint
import pl.dmq.peering.ssh.store.JsonSecretBlob
import java.util.Base64

@Serializable
data class KnownHost(
    val hostname: String,
    val port: Int,
    /** `ssh-ed25519` and the like, kept so a prompt can name it: a different type than last time is not visible from the fingerprint alone. */
    val algorithm: String,
    val publicKey: String,
    val firstSeen: Long,
) {
    val fingerprint: String get() = SshFingerprint.of(Base64.getDecoder().decode(publicKey))
}

/** Kept in the Keystore-sealed store for integrity, not secrecy: a host key anything could rewrite would make the check theatre. */
class KnownHostsStore(secrets: SecretStore) {
    sealed interface Decision {
        data object Unknown : Decision

        data class Match(val known: KnownHost) : Decision

        data class Changed(val known: KnownHost) : Decision
    }

    private val blob = JsonSecretBlob(secrets, KEY, MapSerializer(String.serializer(), KnownHost.serializer()), emptyMap())

    fun all(): Map<String, KnownHost> = blob.load()

    fun host(endpoint: SshEndpoint): KnownHost? = all()[endpoint.key]

    /** Compared byte for byte: the value is public, so exactness is the point, not constant time. */
    fun decision(endpoint: SshEndpoint, publicKey: ByteArray): Decision {
        val known = host(endpoint) ?: return Decision.Unknown
        val same = Base64.getDecoder().decode(known.publicKey).contentEquals(publicKey)
        return if (same) Decision.Match(known) else Decision.Changed(known)
    }

    /** Overwriting is only reached through the first-sight path: a changed key refuses the connection, so an entry is replaced only after the user forgets it. */
    fun record(endpoint: SshEndpoint, algorithm: String, publicKey: ByteArray, nowMillis: Long): Boolean {
        val entry = KnownHost(
            hostname = endpoint.hostname.lowercase(),
            port = endpoint.port,
            algorithm = algorithm,
            publicKey = Base64.getEncoder().encodeToString(publicKey),
            firstSeen = nowMillis,
        )
        return blob.save(all() + (endpoint.key to entry))
    }

    fun forget(endpoint: SshEndpoint): Boolean {
        val current = all()
        return if (endpoint.key in current) blob.save(current - endpoint.key) else true
    }

    private companion object {
        const val KEY = "ssh.knownhosts"
    }
}
