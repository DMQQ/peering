package pl.dmq.peering.ssh.model

import kotlinx.serialization.Serializable

/**
 * A private key and its public half. The public line is derived once, at creation or import, from the private key
 * itself, so a screen never parses keys. The passphrase is kept beside the key because a phone has no ssh-agent.
 */
@Serializable
data class SshKeyPair(val privateKey: String, val publicKey: String, val passphrase: String? = null) {
    val algorithm: String get() = publicKey.substringBefore(' ')

    val comment: String get() = publicKey.split(' ', limit = 3).getOrElse(2) { "" }

    /** Rebuilt from the blob rather than by string surgery, so a comment holding a space still parses back. */
    fun labelled(comment: String): SshKeyPair {
        val trimmed = comment.trim()
        val blob = publicKey.split(' ').getOrElse(1) { "" }
        val line = if (trimmed.isEmpty()) "$algorithm $blob" else "$algorithm $blob $trimmed"
        return copy(publicKey = line)
    }
}
