package pl.dmq.peering.feature.pairing

/** Why a pairing did not finish, in terms the screen can word. [PairingMessage.Refused] carries the Mac's own explanation when it gave one. */
sealed interface PairingMessage {
    data object UnexpectedFrame : PairingMessage

    data object Malformed : PairingMessage

    data object ProtocolMismatch : PairingMessage

    data object HostIdMismatch : PairingMessage

    data object PinMismatch : PairingMessage

    data object NoPinOnFile : PairingMessage

    data object CommitmentMismatch : PairingMessage

    data class Refused(val hostReason: String?) : PairingMessage

    data object Declined : PairingMessage

    data object NotSaved : PairingMessage
    data object Unreachable : PairingMessage
}
