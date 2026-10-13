package pl.dmq.peering.ssh.store

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import pl.dmq.peering.session.ports.Random
import pl.dmq.peering.session.ports.SecretStore
import java.security.MessageDigest
import java.util.Base64

@Serializable
internal data class PasscodeHash(val salt: String, val hash: String)

/**
 * A random salt and the digest of the passcode under it, so equal passcodes on two servers do not share bytes. Six
 * digits are a million possibilities, so the digest is no defence against anyone who can read the blob; the Keystore
 * seal is the protection, and the digest keeps a backup or dump from handing over the number.
 */
class SshPasscodeStore(secrets: SecretStore, private val random: Random) {
    private val blob = JsonSecretBlob(
        secrets,
        KEY,
        MapSerializer(String.serializer(), PasscodeHash.serializer()),
        emptyMap(),
    )

    fun hasPasscode(hostId: String): Boolean = hostId in blob.load()

    /** Whether it was written; a locked server with nothing stored behind it cannot be opened, so the caller must not report success on false. */
    fun set(passcode: String, hostId: String): Boolean {
        if (!isValid(passcode)) return false
        val salt = random.bytes(SALT_BYTES)
        val entry = PasscodeHash(encode(salt), encode(digest(passcode, salt)))
        return blob.save(blob.load() + (hostId to entry))
    }

    /** False for a server with none, so "nothing is stored" can never be a way through a lock. */
    fun verify(passcode: String, hostId: String): Boolean {
        val stored = blob.load()[hostId] ?: return false
        val salt = Base64.getDecoder().decode(stored.salt)
        return MessageDigest.isEqual(digest(passcode, salt), Base64.getDecoder().decode(stored.hash))
    }

    fun remove(hostId: String): Boolean {
        val current = blob.load()
        return if (hostId in current) blob.save(current - hostId) else true
    }

    private fun digest(passcode: String, salt: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").run {
            update(salt)
            digest(passcode.encodeToByteArray())
        }

    private fun encode(bytes: ByteArray) = Base64.getEncoder().encodeToString(bytes)

    companion object {
        const val LENGTH = 6
        private const val SALT_BYTES = 16
        private const val KEY = "ssh.passcodes"

        fun isValid(passcode: String): Boolean = passcode.length == LENGTH && passcode.all { it in '0'..'9' }
    }
}
