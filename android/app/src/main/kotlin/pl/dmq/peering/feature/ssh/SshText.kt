package pl.dmq.peering.feature.ssh

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ssh.model.SshAuthMethod
import pl.dmq.peering.ssh.model.SshForwardError
import pl.dmq.peering.ssh.model.SshHostFormError
import pl.dmq.peering.ssh.transport.SshFailure
import pl.dmq.peering.sshj.SshKeyProblem

/** The sentence for a connection that ended badly. A changed key has its own card, so it is not worded here. */
@Composable
internal fun failureText(failure: SshFailure, method: SshAuthMethod): String = when (failure) {
    is SshFailure.HostKeyRejected -> stringResource(R.string.ssh_fail_rejected)
    is SshFailure.HostKeyChanged -> stringResource(R.string.ssh_changed_body)
    is SshFailure.AuthenticationFailed ->
        stringResource(if (method == SshAuthMethod.KEY) R.string.ssh_fail_auth_key else R.string.ssh_fail_auth_password)
    is SshFailure.TimedOut -> stringResource(R.string.ssh_fail_timeout)
    is SshFailure.Transport -> failure.reason
    is SshFailure.Browse -> failure.reason
    is SshFailure.Forward -> failure.reason
    is SshFailure.NotConnected -> stringResource(R.string.ssh_fail_ended)
}

@Composable
internal fun hostErrorText(error: SshHostFormError): String = stringResource(
    when (error) {
        SshHostFormError.HOSTNAME_EMPTY -> R.string.ssh_error_host_empty
        SshHostFormError.HOSTNAME_INVALID -> R.string.ssh_error_host_invalid
        SshHostFormError.PORT_INVALID -> R.string.ssh_error_port
        SshHostFormError.USERNAME_EMPTY -> R.string.ssh_error_user
    },
)

@Composable
internal fun forwardErrorText(error: SshForwardError, port: Int?): String = when (error) {
    SshForwardError.LOCAL_PORT_NOT_A_NUMBER -> stringResource(R.string.ssh_forward_err_local_nan)
    SshForwardError.LOCAL_PORT_OUT_OF_RANGE -> stringResource(R.string.ssh_forward_err_local_range)
    SshForwardError.REMOTE_PORT_NOT_A_NUMBER -> stringResource(R.string.ssh_forward_err_remote_nan)
    SshForwardError.REMOTE_PORT_OUT_OF_RANGE -> stringResource(R.string.ssh_forward_err_remote_range)
    SshForwardError.REMOTE_HOST_EMPTY -> stringResource(R.string.ssh_forward_err_host_empty)
    SshForwardError.REMOTE_HOST_NOT_A_HOSTNAME -> stringResource(R.string.ssh_forward_err_host_invalid)
    SshForwardError.LOCAL_PORT_ALREADY_USED -> stringResource(R.string.ssh_forward_err_used, port ?: 0)
}

@Composable
internal fun keyProblemText(problem: SshKeyProblem): String = when (problem) {
    is SshKeyProblem.NotAPrivateKey -> stringResource(R.string.ssh_key_err_not_private)
    is SshKeyProblem.Malformed -> stringResource(R.string.ssh_key_err_malformed, problem.reason)
    is SshKeyProblem.PassphraseNeeded -> stringResource(R.string.ssh_key_err_needs_passphrase)
    is SshKeyProblem.PassphraseWrong -> stringResource(R.string.ssh_key_err_wrong_passphrase)
}
