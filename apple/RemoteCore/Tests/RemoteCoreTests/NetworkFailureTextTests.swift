import Foundation
import Network
import Testing

@testable import RemoteCore

/// An `NWError` is not a `LocalizedError`, so its `localizedDescription` leaks `Network.NWError error 60`; each case asserts the raw error is gone.
@Suite("Network failure text")
struct NetworkFailureTextTests {
    @Test func aTimedOutConnectionIsASentenceAndNotTheError() {
        let text = NetworkFailureText.describe(NWError.posix(.ETIMEDOUT))

        #expect(!text.contains("NWError"))
        #expect(!text.contains("60"))
        #expect(text == "The Mac did not answer. Check that both devices are on the same network.")
    }

    /// 54 is the common one (Mac quit, rebuilt or slept) and says nothing about this device.
    @Test func aResetByPeerBlamesTheMacAndNotThePhone() {
        let text = NetworkFailureText.describe(NWError.posix(.ECONNRESET))

        #expect(text == "The Mac closed the connection. It may have quit, restarted, or gone to sleep.")
    }

    @Test func aRefusedConnectionPointsAtTheMacRunningTheApp() {
        let text = NetworkFailureText.describe(NWError.posix(.ECONNREFUSED))

        #expect(text.contains("Peering is running"))
    }

    @Test func anUnrecognisedCodeDoesNotPrintTheCode() {
        let text = NetworkFailureText.describe(NWError.posix(.EAFNOSUPPORT))

        #expect(text == "The connection to the Mac failed.")
        #expect(!text.contains("47"))
    }

    /// A framing failure carries a description worth keeping: the ends disagreeing about the protocol is the message.
    @Test func anErrorWithItsOwnWordingKeepsIt() {
        let text = NetworkFailureText.describe(FramingError.unknownKind(0x7F))

        #expect(text == "The Mac sent a message this app does not recognise. Update whichever end is older.")
    }

    /// A sleeping Mac used to produce the identity sentence, advising to forget the pairing and pair again. No ordinary transport failure may say anything about pinned keys.
    @Test func noTransportFailureReadsAsAnIdentityChange() {
        let failures: [NWError] = [
            .posix(.ECONNRESET), .posix(.ECONNREFUSED), .posix(.ETIMEDOUT),
            .posix(.EHOSTDOWN), .posix(.EHOSTUNREACH), .posix(.EPIPE),
        ]

        for failure in failures {
            let text = NetworkFailureText.describe(failure)
            #expect(!text.contains("pinned"), "\(failure) reads as an identity change")
            #expect(!text.contains("pair again"), "\(failure) tells the user to break a pairing")
        }
    }

    @Test func aPinMismatchNamesTheIdentityAndTheWayOut() {
        let text = NetworkFailureText.describe(
            ClientSession.Failure.pinMismatch(hostID: "mac-1")
        )

        #expect(text.contains("not the Mac you paired with"))
        #expect(text.contains("pair again"))
    }

    /// No pin on file is a different fault from a mismatch and must not say the Mac's identity changed.
    @Test func havingNoPinOnFileIsNotAMismatch() {
        let text = NetworkFailureText.describe(
            ClientSession.Failure.noPinOnFile(hostID: "mac-1")
        )

        #expect(text.contains("no pairing on file"))
        #expect(!text.contains("pinned"))
    }

    @Test func anOpaqueErrorIsStillASentence() {
        struct Opaque: Error {}
        let text = NetworkFailureText.describe(Opaque())

        #expect(text == "The connection to the Mac failed.")
        #expect(!text.contains("Opaque"))
    }
}
