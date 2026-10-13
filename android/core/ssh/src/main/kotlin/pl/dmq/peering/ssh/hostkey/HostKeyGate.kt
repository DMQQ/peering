package pl.dmq.peering.ssh.hostkey

import pl.dmq.peering.ssh.model.SshEndpoint
import pl.dmq.peering.ssh.transport.SshFailure

/** The algorithm is carried beside the fingerprint because it explains a change: `ssh-ed25519` then `rsa-sha2-256` changes the fingerprint without an attack. */
data class HostKeyPrompt(val endpoint: SshEndpoint, val algorithm: String, val fingerprint: String)

/** A key as the server presented it: [blob] is the SSH wire encoding that OpenSSH hashes. */
class OfferedHostKey(val endpoint: SshEndpoint, val algorithm: String, val blob: ByteArray) {
    val prompt: HostKeyPrompt get() = HostKeyPrompt(endpoint, algorithm, SshFingerprint.of(blob))
}

/**
 * Three outcomes that differ: a known key passes silently, a changed key fails outright, and a new one suspends the
 * handshake on a human. The transport calls [verify] mid-handshake, before anything assumes a trusted peer.
 */
class HostKeyGate(
    private val store: KnownHostsStore,
    private val nowMillis: () -> Long,
    private val ask: suspend (HostKeyPrompt) -> Boolean,
) {
    /** Returns when the key is trusted; throws [SshFailure.HostKeyChanged] or [SshFailure.HostKeyRejected] otherwise. */
    suspend fun verify(offered: OfferedHostKey) {
        val prompt = offered.prompt
        when (val decision = store.decision(offered.endpoint, offered.blob)) {
            is KnownHostsStore.Decision.Match -> Unit
            is KnownHostsStore.Decision.Changed -> throw SshFailure.HostKeyChanged(decision.known, prompt)
            KnownHostsStore.Decision.Unknown -> {
                if (!ask(prompt)) throw SshFailure.HostKeyRejected(prompt)
                // An unsaved key would be asked about again on every connection, and a changed one could then slip in unremarked.
                if (!store.record(offered.endpoint, offered.algorithm, offered.blob, nowMillis())) {
                    throw SshFailure.Transport("The server's key could not be saved, so the connection was not made.")
                }
            }
        }
    }
}
