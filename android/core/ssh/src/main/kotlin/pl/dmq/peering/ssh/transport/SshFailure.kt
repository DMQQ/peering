package pl.dmq.peering.ssh.transport

import pl.dmq.peering.ssh.hostkey.HostKeyPrompt
import pl.dmq.peering.ssh.hostkey.KnownHost

/** Everything a connection can end in that the user needs told apart. */
sealed class SshFailure(message: String) : Exception(message) {
    class HostKeyRejected(val prompt: HostKeyPrompt) : SshFailure("The host key was not accepted.")

    /**
     * A known host offered a different key. Deliberately not reachable by agreeing to something: a one-tap accept
     * would turn the check into a formality, since the moment it matters is when the user is hurried.
     */
    class HostKeyChanged(val known: KnownHost, val presented: HostKeyPrompt) : SshFailure("The host key changed.")

    class AuthenticationFailed(val method: String) : SshFailure("The server refused the sign-in.")

    class TimedOut : SshFailure("The server did not answer in time.")

    /** [reason] is the library's own sentence, shown as is. */
    class Transport(val reason: String) : SshFailure(reason)

    /** Not a variant of [Transport]: a missing folder or a server with no SFTP is an ordinary answer, not a broken connection. */
    class Browse(val reason: String) : SshFailure(reason)

    class Forward(val reason: String) : SshFailure(reason)

    class NotConnected : SshFailure("The connection ended.")
}
