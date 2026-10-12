package pl.dmq.peering.feature.pairing

import pl.dmq.peering.wire.PairingPayloadError

/** Why typed or scanned text is not a Mac's device ID. The screen words each one. */
enum class HostIdError {
    Empty,
    CodeInsteadOfId,
    NotPairingCode,
    NotAnIdentifier;

    companion object {
        fun of(error: PairingPayloadError): HostIdError = when (error) {
            PairingPayloadError.EmptyInput -> Empty
            PairingPayloadError.ShortAuthenticationCode -> CodeInsteadOfId
            PairingPayloadError.UnrecognisedCode -> NotPairingCode
            is PairingPayloadError.NotAnIdentifier -> NotAnIdentifier
        }
    }
}
