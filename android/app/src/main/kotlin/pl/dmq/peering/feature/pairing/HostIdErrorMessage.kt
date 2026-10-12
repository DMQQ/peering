package pl.dmq.peering.feature.pairing

import androidx.annotation.StringRes
import pl.dmq.peering.R

@StringRes
internal fun HostIdError.messageRes(): Int = when (this) {
    HostIdError.Empty -> R.string.pairing_error_empty
    HostIdError.CodeInsteadOfId -> R.string.pairing_error_code_instead_of_id
    HostIdError.NotPairingCode -> R.string.pairing_error_not_pairing_code
    HostIdError.NotAnIdentifier -> R.string.pairing_error_not_identifier
}
