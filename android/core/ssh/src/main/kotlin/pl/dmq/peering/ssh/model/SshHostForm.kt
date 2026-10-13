package pl.dmq.peering.ssh.model

enum class SshHostFormError { HOSTNAME_EMPTY, HOSTNAME_INVALID, PORT_INVALID, USERNAME_EMPTY }

sealed interface SshHostFormReading {
    data class Valid(val host: SshHost) : SshHostFormReading

    data class Invalid(val errors: Set<SshHostFormError>) : SshHostFormReading
}

/** The editor's fields as typed. Reading them is per keystroke, so it takes strings and reports every problem at once. */
data class SshHostForm(
    val name: String = "",
    val hostname: String = "",
    val port: String = SshEndpoint.DEFAULT_PORT.toString(),
    val username: String = "",
    val lock: SshHostLock = SshHostLock.OFF,
) {
    /** [existing] carries what the form does not edit (forwards, last connection), so saving a change keeps it. */
    fun reading(existing: SshHost?, newId: () -> String, nowMillis: () -> Long): SshHostFormReading {
        val errors = mutableSetOf<SshHostFormError>()
        val host = hostname.trim()
        if (host.isEmpty()) {
            errors += SshHostFormError.HOSTNAME_EMPTY
        } else if (host.any { it.isWhitespace() || it == '/' || it == '@' }) {
            errors += SshHostFormError.HOSTNAME_INVALID
        }
        val portNumber = port.trim().toIntOrNull()
        if (portNumber == null || portNumber !in 1..65535) errors += SshHostFormError.PORT_INVALID
        val user = username.trim()
        if (user.isEmpty()) errors += SshHostFormError.USERNAME_EMPTY
        if (errors.isNotEmpty() || portNumber == null) return SshHostFormReading.Invalid(errors)
        val base = existing ?: SshHost(newId(), hostname = host, username = user, createdAt = nowMillis())
        return SshHostFormReading.Valid(
            base.copy(name = name.trim(), hostname = host, port = portNumber, username = user, lock = lock),
        )
    }

    companion object {
        fun of(host: SshHost) = SshHostForm(host.name, host.hostname, host.port.toString(), host.username, host.lock)
    }
}
