package pl.dmq.peering.feature.pairing

import pl.dmq.peering.session.connection.FailureReason

internal fun FailureReason.toPairingMessage(): PairingMessage = when (this) {
    is FailureReason.UnexpectedFrame -> PairingMessage.UnexpectedFrame
    is FailureReason.MalformedMessage -> PairingMessage.Malformed
    is FailureReason.ProtocolMismatch -> PairingMessage.ProtocolMismatch
    is FailureReason.HostIdMismatch -> PairingMessage.HostIdMismatch
    is FailureReason.PinMismatch -> PairingMessage.PinMismatch
    is FailureReason.NoPinOnFile -> PairingMessage.NoPinOnFile
    FailureReason.CommitmentMismatch -> PairingMessage.CommitmentMismatch
    is FailureReason.PairingRefused -> PairingMessage.Refused(reason)
    FailureReason.PairingDeclined -> PairingMessage.Declined
    FailureReason.PairingNotSaved -> PairingMessage.NotSaved
    FailureReason.Unreachable -> PairingMessage.Unreachable
}
