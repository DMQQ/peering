package pl.dmq.peering.feature.pairing

import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.controller.ConnectFailureKind

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

internal fun ConnectFailureKind.toPairingMessage(): PairingMessage = when (this) {
    ConnectFailureKind.Unreachable -> PairingMessage.Unreachable
    ConnectFailureKind.Refused -> PairingMessage.ConnectionRefused
    ConnectFailureKind.TlsFailed -> PairingMessage.TlsFailed
    ConnectFailureKind.Timeout -> PairingMessage.TimedOut
}
