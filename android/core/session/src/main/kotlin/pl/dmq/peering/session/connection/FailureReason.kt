package pl.dmq.peering.session.connection

import pl.dmq.peering.wire.MessageKind

/** Why a handshake ended. Carries data, not text: the caller words it for the user. */
sealed interface FailureReason {
    data class UnexpectedFrame(val received: MessageKind, val expected: String) : FailureReason

    data class MalformedMessage(val kind: MessageKind) : FailureReason

    data class ProtocolMismatch(val client: Int, val host: Int) : FailureReason

    data class HostIdMismatch(val dialled: String, val answered: String) : FailureReason

    data class PinMismatch(val hostId: String) : FailureReason

    /** The host claims it is already paired, but this device holds no pin for it, so the claim proves nothing. */
    data class NoPinOnFile(val hostId: String) : FailureReason

    data object CommitmentMismatch : FailureReason

    /** [reason] is the host's own explanation, or null when it gave none. */
    data class PairingRefused(val reason: String?) : FailureReason

    data object PairingDeclined : FailureReason

    data object PairingNotSaved : FailureReason
}
