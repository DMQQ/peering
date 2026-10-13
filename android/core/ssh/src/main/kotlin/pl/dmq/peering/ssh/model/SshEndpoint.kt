package pl.dmq.peering.ssh.model

/** What the protocol needs: every connection and known-hosts lookup starts here, saved or not. */
data class SshEndpoint(val hostname: String, val port: Int = DEFAULT_PORT) {
    /** Lowercased because hostnames are case-insensitive. The port is always present: one host on two ports is two servers with two keys. */
    val key: String get() = "${hostname.lowercase()}:$port"

    val display: String get() = if (port == DEFAULT_PORT) hostname else "$hostname:$port"

    companion object {
        const val DEFAULT_PORT = 22
    }
}
