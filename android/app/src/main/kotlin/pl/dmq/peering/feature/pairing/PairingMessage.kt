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

    /** The user gave a wrong code too many times, so the phone stopped the pairing. */
    data object TooManyAttempts : PairingMessage

    data object Unreachable : PairingMessage

    data object ConnectionRefused : PairingMessage

    data object TlsFailed : PairingMessage

    data object TimedOut : PairingMessage

    /** The computer closed the connection or stopped answering while the pairing was under way. */
    data object Closed : PairingMessage
}
