package pl.dmq.peering.sshj

import net.schmizz.keepalive.KeepAliveProvider
import net.schmizz.sshj.Config
import net.schmizz.sshj.DefaultConfig
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.userauth.UserAuthException
import net.schmizz.sshj.userauth.method.AuthKeyboardInteractive
import net.schmizz.sshj.userauth.method.AuthPassword
import net.schmizz.sshj.userauth.method.PasswordResponseProvider
import net.schmizz.sshj.userauth.password.PasswordFinder
import net.schmizz.sshj.userauth.password.PasswordUtils
import pl.dmq.peering.ssh.hostkey.HostKeyGate
import pl.dmq.peering.ssh.model.SshCredential
import pl.dmq.peering.ssh.transport.SshConnectRequest
import pl.dmq.peering.ssh.transport.SshConnection
import pl.dmq.peering.ssh.transport.SshFailure
import pl.dmq.peering.ssh.transport.SshTransport
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * The sshj end of [SshTransport]. A fresh client per connection, so nothing is shared between servers. The default
 * config rather than sshj's AndroidConfig, which drops ECDSA host keys: [SshProviders] swaps in the full provider that
 * AndroidConfig exists to work around, and a server whose only host key is ECDSA must still be reachable.
 */
class SshjTransport(private val newConfig: () -> Config = { DefaultConfig() }) : SshTransport {
    override fun connect(request: SshConnectRequest, gate: HostKeyGate): SshConnection {
        SshProviders.install()
        val config = newConfig().apply { keepAliveProvider = KeepAliveProvider.KEEP_ALIVE }
        val client = SSHClient(config)
        val verifier = GateVerifier(request.endpoint, gate)
        client.addHostKeyVerifier(verifier)
        client.connectTimeout = request.connectTimeoutMillis
        // Reads time out only while connecting, so a port that accepts and never speaks ends; an idle shell must not.
        client.timeout = request.connectTimeoutMillis
        try {
            client.connect(request.endpoint.hostname, request.endpoint.port)
            authenticate(client, request)
            client.timeout = 0
        } catch (failure: Exception) {
            client.runCatching { disconnect() }
            throw verifier.failure ?: translate(failure, request.credential)
        }
        client.connection.keepAlive.keepAliveInterval = KEEP_ALIVE_SECONDS
        return SshjConnection(client)
    }

    private fun authenticate(client: SSHClient, request: SshConnectRequest) {
        when (val credential = request.credential) {
            is SshCredential.Password -> client.auth(
                request.username,
                AuthPassword(oneOff(credential.password)),
                AuthKeyboardInteractive(PasswordResponseProvider(oneOff(credential.password))),
            )
            is SshCredential.Key -> {
                val finder = credential.pair.passphrase?.let(::oneOff)
                client.authPublickey(request.username, client.loadKeys(credential.pair.privateKey, null, finder))
            }
        }
    }

    private fun oneOff(secret: String): PasswordFinder = PasswordUtils.createOneOff(secret.toCharArray())

    private fun translate(failure: Exception, credential: SshCredential): SshFailure {
        if (failure is SshFailure) return failure
        if (failure is UserAuthException) return SshFailure.AuthenticationFailed(credential.method.name.lowercase())
        if (generateSequence<Throwable>(failure) { it.cause }.any { it is SocketTimeoutException }) return SshFailure.TimedOut()
        return when (failure) {
            is UnknownHostException -> SshFailure.Transport("That host name could not be found.")
            is ConnectException -> SshFailure.Transport("The server refused the connection. Check the host and the port.")
            is NoRouteToHostException -> SshFailure.Transport("There is no route to that host.")
            else -> SshFailure.Transport(failure.message ?: "The connection failed.")
        }
    }

    private companion object {
        const val KEEP_ALIVE_SECONDS = 15
    }
}
