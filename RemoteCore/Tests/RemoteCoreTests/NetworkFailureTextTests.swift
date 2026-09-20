import Foundation
import Network
import Testing

@testable import RemoteCore

/// What the user is told when the network is what went wrong.
///
/// The failure this guards against is not a wrong sentence, it is a *non*-sentence: an `NWError`
/// is not a `LocalizedError`, so `localizedDescription` on one falls through to
/// `String(describing:)` and puts `Network.NWError error 60` in a notification. Nothing about that
/// is specific to one code path, which is why every case here asserts that the raw error is *gone*
/// as well as that something was said.
@Suite("Network failure text")
struct NetworkFailureTextTests {
    /// The regression, stated as the user met it: a connection that timed out.
    @Test func aTimedOutConnectionIsASentenceAndNotTheError() {
        let text = NetworkFailureText.describe(NWError.posix(.ETIMEDOUT))

        #expect(!text.contains("NWError"))
        #expect(!text.contains("60"))
        #expect(text == "The Mac did not answer. Check that both devices are on the same network.")
    }

    /// 54 is the one that happens most: the Mac quit, was rebuilt, or went to sleep. It says
    /// nothing about this device, and the sentence must not imply that it does.
    @Test func aResetByPeerBlamesTheMacAndNotThePhone() {
        let text = NetworkFailureText.describe(NWError.posix(.ECONNRESET))

        #expect(text == "The Mac closed the connection. It may have quit, restarted, or gone to sleep.")
    }

    @Test func aRefusedConnectionPointsAtTheMacRunningTheApp() {
        let text = NetworkFailureText.describe(NWError.posix(.ECONNREFUSED))

        #expect(text.contains("Peering is running"))
    }

    /// A code nobody has seen still has to read as a sentence. It deliberately drops the number:
    /// a user cannot act on `error 65`, and the raw error is in the log beside the session.
    @Test func anUnrecognisedCodeDoesNotPrintTheCode() {
        let text = NetworkFailureText.describe(NWError.posix(.EAFNOSUPPORT))

        #expect(text == "The connection to the Mac failed.")
        #expect(!text.contains("47"))
    }

    /// A framing failure is the app's own error rather than the network's, and it carries a
    /// description worth keeping — the two ends disagreeing about the protocol is the whole
    /// message, and "the connection failed" would throw it away.
    @Test func anErrorWithItsOwnWordingKeepsIt() {
        let text = NetworkFailureText.describe(FramingError.unknownKind(0x7F))

        #expect(text == "The Mac sent a message this app does not recognise. Update whichever end is older.")
    }

    /// **The regression, and it was not in this table.** A Mac that was asleep used to produce the
    /// identity sentence: the connect path asked whether a pin was *in force*, which is true of
    /// every paired Mac, rather than whether the failure was about the pin. So the table below was
    /// bypassed for exactly the Macs people actually connect to, and the advice that came out of it
    /// was "forget it here and pair again", which destroys a working pairing over a sleeping Mac.
    ///
    /// What is asserted is the property that made that possible: no ordinary transport failure says
    /// anything about pinned keys. The branch that used to overrule this is gone rather than
    /// narrowed, which is why this is the whole of the guard.
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

    /// A real mismatch says what it is and what to do about it, because the only way forward is to
    /// pair again and the person reading this is one tap from doing it.
    @Test func aPinMismatchNamesTheIdentityAndTheWayOut() {
        let text = NetworkFailureText.describe(
            ClientSession.Failure.pinMismatch(hostID: "mac-1")
        )

        #expect(text.contains("not the Mac you paired with"))
        #expect(text.contains("pair again"))
    }

    /// Dialling a device ID with nothing on file for it is a different fault with a different
    /// sentence. It shared a case with the mismatch above, and therefore shared its words, which
    /// told somebody their Mac's identity had changed when this phone had never met it.
    @Test func havingNoPinOnFileIsNotAMismatch() {
        let text = NetworkFailureText.describe(
            ClientSession.Failure.noPinOnFile(hostID: "mac-1")
        )

        #expect(text.contains("no pairing on file"))
        #expect(!text.contains("pinned"))
    }

    /// And nothing at all to say still has to be said without an enum name in it, which is the
    /// case this used to get wrong: `"\(error)"` on any error at all.
    @Test func anOpaqueErrorIsStillASentence() {
        struct Opaque: Error {}
        let text = NetworkFailureText.describe(Opaque())

        #expect(text == "The connection to the Mac failed.")
        #expect(!text.contains("Opaque"))
    }
}
