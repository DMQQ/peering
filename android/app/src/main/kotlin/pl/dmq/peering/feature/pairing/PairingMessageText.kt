package pl.dmq.peering.feature.pairing

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R

@Composable
internal fun PairingMessage.text(): String = when (this) {
    PairingMessage.UnexpectedFrame -> stringResource(R.string.pairing_failed_unexpected)
    PairingMessage.Malformed -> stringResource(R.string.pairing_failed_malformed)
    PairingMessage.ProtocolMismatch -> stringResource(R.string.pairing_failed_protocol)
    PairingMessage.HostIdMismatch -> stringResource(R.string.pairing_failed_host_id)
    PairingMessage.PinMismatch -> stringResource(R.string.pairing_failed_pin)
    PairingMessage.NoPinOnFile -> stringResource(R.string.pairing_failed_no_pin)
    PairingMessage.CommitmentMismatch -> stringResource(R.string.pairing_failed_commitment)
    is PairingMessage.Refused -> hostReason
        ?.let { stringResource(R.string.pairing_failed_refused_reason, it) }
        ?: stringResource(R.string.pairing_failed_refused)
    PairingMessage.Declined -> stringResource(R.string.pairing_failed_declined)
    PairingMessage.NotSaved -> stringResource(R.string.pairing_failed_not_saved)
    PairingMessage.TooManyAttempts -> stringResource(R.string.pairing_failed_too_many)
    PairingMessage.Unreachable -> stringResource(R.string.pairing_failed_unreachable)
}
