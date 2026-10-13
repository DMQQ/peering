package pl.dmq.peering.ssh.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** A property of the server rather than of the app, since the machines are not equally sensitive. */
@Serializable
enum class SshHostLock {
    @SerialName("off")
    OFF,

    @SerialName("passcode")
    PASSCODE,

    @SerialName("biometrics")
    BIOMETRICS,
    ;

    val isLocked: Boolean get() = this != OFF
}
