package pl.dmq.peering.sshj

import kotlinx.coroutines.runBlocking
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.common.KeyType
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import pl.dmq.peering.ssh.hostkey.HostKeyGate
import pl.dmq.peering.ssh.hostkey.OfferedHostKey
import pl.dmq.peering.ssh.model.SshEndpoint
import pl.dmq.peering.ssh.transport.SshFailure
import java.security.PublicKey

/**
 * sshj asks synchronously, on the thread that is connecting, so waiting on the user's answer here simply holds the
 * handshake. A refusal is kept in [failure]: sshj turns it into a generic "could not verify" that would hide whether
 * the key was new, refused or changed.
 */
internal class GateVerifier(private val endpoint: SshEndpoint, private val gate: HostKeyGate) : HostKeyVerifier {
    @Volatile
    var failure: SshFailure? = null
        private set

    override fun verify(hostname: String, port: Int, key: PublicKey): Boolean {
        val blob = Buffer.PlainBuffer().putPublicKey(key).compactData
        val offered = OfferedHostKey(endpoint, KeyType.fromKey(key).toString(), blob)
        return try {
            runBlocking { gate.verify(offered) }
            true
        } catch (refusal: SshFailure) {
            failure = refusal
            false
        }
    }

    override fun findExistingAlgorithms(hostname: String, port: Int): List<String> = emptyList()
}
