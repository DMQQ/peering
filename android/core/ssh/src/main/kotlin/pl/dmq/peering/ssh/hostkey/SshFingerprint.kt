package pl.dmq.peering.ssh.hostkey

import java.security.MessageDigest
import java.util.Base64

/**
 * Byte-identical to `ssh-keygen -lf`, so the user can check it by another route: `SHA256:` then the base64 of the
 * SHA-256 of the whole public key blob, with the `=` padding removed (where OpenSSH departs from base64).
 */
object SshFingerprint {
    fun of(publicKeyBlob: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(publicKeyBlob)
        return "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(digest)
    }
}
