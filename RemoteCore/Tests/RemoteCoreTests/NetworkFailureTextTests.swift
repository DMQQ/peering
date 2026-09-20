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

    /// And nothing at all to say still has to be said without an enum name in it, which is the
    /// case this used to get wrong: `"\(error)"` on any error at all.
    @Test func anOpaqueErrorIsStillASentence() {
        struct Opaque: Error {}
        let text = NetworkFailureText.describe(Opaque())

        #expect(text == "The connection to the Mac failed.")
        #expect(!text.contains("Opaque"))
    }
}
