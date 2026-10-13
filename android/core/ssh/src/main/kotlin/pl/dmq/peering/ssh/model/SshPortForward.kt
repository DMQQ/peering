package pl.dmq.peering.ssh.model

import kotlinx.serialization.Serializable

/** Why an editor's fields were refused; the app turns each into the sentence that names the field at fault. */
enum class SshForwardError {
    LOCAL_PORT_NOT_A_NUMBER,
    LOCAL_PORT_OUT_OF_RANGE,
    REMOTE_PORT_NOT_A_NUMBER,
    REMOTE_PORT_OUT_OF_RANGE,
    REMOTE_HOST_EMPTY,
    REMOTE_HOST_NOT_A_HOSTNAME,

    /** Another forward on this server already listens on that port; the second to start would lose. */
    LOCAL_PORT_ALREADY_USED,
}

sealed interface SshForwardReading {
    data class Valid(val forward: SshPortForward) : SshForwardReading

    data class Invalid(val error: SshForwardError, val port: Int? = null) : SshForwardReading
}

/**
 * OpenSSH's `-L`: the listener is on the phone and the connection is made by the server. The listener is always on
 * 127.0.0.1, since 0.0.0.0 would silently expose the far end to every device on the network.
 */
@Serializable
data class SshPortForward(
    val id: String,
    val label: String = "",
    val localPort: Int,
    val remoteHost: String,
    val remotePort: Int,
    /** Stored because the answer must survive the app closing: a forward the user turned off must not come back on. */
    val isEnabled: Boolean = true,
) {
    val displayName: String get() = label.ifEmpty { "$localPort to $remoteHost:$remotePort" }

    val detail: String get() = "localhost:$localPort to $remoteHost:$remotePort"

    companion object {
        private val PORTS = 1..65535

        /** Takes strings because this runs per keystroke and the caller should not decide what "not a number yet" means. */
        fun reading(
            label: String,
            localPort: String,
            remoteHost: String,
            remotePort: String,
            existing: List<SshPortForward> = emptyList(),
            editing: String? = null,
            newId: () -> String,
        ): SshForwardReading {
            val local = localPort.trim().toIntOrNull()
                ?: return SshForwardReading.Invalid(SshForwardError.LOCAL_PORT_NOT_A_NUMBER)
            if (local !in PORTS) return SshForwardReading.Invalid(SshForwardError.LOCAL_PORT_OUT_OF_RANGE)
            if (existing.any { it.localPort == local && it.id != editing }) {
                return SshForwardReading.Invalid(SshForwardError.LOCAL_PORT_ALREADY_USED, local)
            }
            val host = remoteHost.trim()
            if (host.isEmpty()) return SshForwardReading.Invalid(SshForwardError.REMOTE_HOST_EMPTY)
            if (!isHostname(host)) return SshForwardReading.Invalid(SshForwardError.REMOTE_HOST_NOT_A_HOSTNAME)
            val remote = remotePort.trim().toIntOrNull()
                ?: return SshForwardReading.Invalid(SshForwardError.REMOTE_PORT_NOT_A_NUMBER)
            if (remote !in PORTS) return SshForwardReading.Invalid(SshForwardError.REMOTE_PORT_OUT_OF_RANGE)
            val previous = existing.firstOrNull { it.id == editing }
            return SshForwardReading.Valid(
                SshPortForward(editing ?: newId(), label.trim(), local, host, remote, previous?.isEnabled ?: true),
            )
        }

        /** Deliberately loose: the name is resolved on the server. It rejects a whole command line pasted from a tutorial. */
        private fun isHostname(text: String) = text.all { it.isLetterOrDigit() || it in ".-:_" }
    }
}
