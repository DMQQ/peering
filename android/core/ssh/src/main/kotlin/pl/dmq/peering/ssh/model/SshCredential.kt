package pl.dmq.peering.ssh.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** A sealed type rather than a nullable password, so key auth is a case and adding one needs no migration. */
@Serializable
sealed interface SshCredential {
    @Serializable
    @SerialName("password")
    data class Password(val password: String) : SshCredential

    @Serializable
    @SerialName("key")
    data class Key(val pair: SshKeyPair) : SshCredential

    val method: SshAuthMethod
        get() = when (this) {
            is Password -> SshAuthMethod.PASSWORD
            is Key -> SshAuthMethod.KEY
        }
}
