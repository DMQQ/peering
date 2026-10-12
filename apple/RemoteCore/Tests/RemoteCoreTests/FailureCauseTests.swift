import Foundation
import Network
import Testing

@testable import RemoteCore

@Suite("Failure causes")
struct FailureCauseTests {
    typealias Cause = ClientSession.FailureCause

    @Test("the failures the user can act on map to a cause without any name in it")
    func sessionFailures() {
        #expect(Cause(ClientSession.Failure.pinsUnreadable) == .pinsUnreadable)
        #expect(Cause(ClientSession.Failure.handshakeTimedOut) == .handshakeTimedOut)
        #expect(Cause(ClientSession.Failure.busy) == .sessionBusy)
        #expect(Cause(ClientSession.Failure.noServerKey) == .handshakeUnreadable)
    }

    @Test("a failure that names a Mac or a version keeps the name as a value of its cause")
    func namedFailures() {
        #expect(Cause(ClientSession.Failure.pinMismatch(hostID: "a")) == .identityChanged(hostID: "a"))
        #expect(Cause(ClientSession.Failure.noPinOnFile(hostID: "a")) == .noPinOnFile(hostID: "a"))
        #expect(Cause(ClientSession.Failure.hostIDMismatch(dialled: "a", answered: "b")) == .hostIDMismatch(dialled: "a", answered: "b"))
        #expect(Cause(ClientSession.Failure.protocolMismatch(client: 1, host: 2)) == .protocolMismatch(client: 1, host: 2))
        #expect(Cause(ClientSession.Failure.identity("x")) == nil)
    }

    @Test("a refusal keeps the words of whoever refused")
    func refusals() {
        #expect(Cause(RelaySignallingError.refused(code: "relayFull", message: "busy")) == .relayRefused(message: "busy"))
        #expect(Cause(ClientConnection.Failure.refused("no")) == .hostRefused(message: "no"))
    }

    @Test("the relay's version refusal gives both numbers, or nil for a number it cannot read")
    func relayVersionRefusal() {
        #expect(Cause(RelaySignallingError.refused(code: "version", message: "host speaks v12, client speaks v11")) == .relayVersionMismatch(host: 12, client: 11))
        #expect(Cause(RelaySignallingError.refused(code: "version", message: "host speaks vx, client speaks v3")) == .relayVersionMismatch(host: nil, client: 3))
        #expect(Cause(RelaySignallingError.refused(code: "version", message: "no")) == .relayVersionMismatch(host: nil, client: nil))
    }

    @Test("every relay signalling failure the app words has a cause")
    func relayFailures() {
        #expect(Cause(RelaySignallingError.timedOut) == .relayTimedOut)
        #expect(Cause(RelaySignallingError.hostOffline("a")) == .relayHostOffline)
        #expect(Cause(RelaySignallingError.unexpectedResponse) == .relayUnavailable)
        #expect(Cause(RelaySignallingError.nonWebSocketResponse) == .relayUnavailable)
    }

    @Test("a network error keeps its kind through the connection failure")
    func networkFailures() {
        let reset = ClientConnection.Failure.transport(from: NWError.posix(.ECONNRESET))
        #expect(reset == .network(.connectionReset))
        #expect(Cause(reset) == .network(.connectionReset))
        #expect(ClientSession.FailureReason(reset) == .transport)
        #expect(Cause(ClientConnection.Failure.transport(from: NWError.posix(.EBADF))) == .network(.failed))
        #expect(Cause(ClientConnection.Failure.timedOut(10)) == .connectTimedOut)
        #expect(Cause(ClientConnection.Failure.hostClosed) == .hostClosed)
    }

    @Test("the English sentence for a network kind is the one the log has always had")
    func networkSentencesUnchanged() {
        #expect(NetworkFailureText.describe(NWError.posix(.ETIMEDOUT)) == "The Mac did not answer. Check that both devices are on the same network.")
        #expect(ClientConnection.Failure.network(.hostDown).errorDescription == "The Mac is switched off or asleep.")
        #expect(Set(NetworkFailureText.Kind.allCases.map(NetworkFailureText.sentence(for:))).count == NetworkFailureText.Kind.allCases.count)
    }

    @Test("a framing error ends the stream as unreadable, not as a network failure")
    func framingFailure() {
        let failure = ClientConnection.Failure.transport(from: FramingError.zeroLengthFrame)
        #expect(Cause(failure) == .handshakeUnreadable)
    }

    @Test("the connect screen card follows from the cause alone")
    func cards() {
        #expect(Cause.relayHostOffline.card == .hostNotRegistered)
        #expect(Cause.identityChanged(hostID: "a").card == .identityChanged)
        #expect(Cause.hostIDMismatch(dialled: "a", answered: "b").card == .wrongMac)
        #expect(Cause.relayVersionMismatch(host: 12, client: 11).card == .updateThisApp)
        #expect(Cause.relayVersionMismatch(host: 11, client: 12).card == .updateTheMac)
        #expect(Cause.relayVersionMismatch(host: nil, client: 11).card == .updateTheMac)
        #expect(Cause.hostClosed.card == nil)
    }

    @Test("only a Keychain refusal is one that unlocking the device can fix")
    func keychainRefusal() {
        #expect(SelfSignedIdentity.Failure.keychain(-25308).isKeychainRefusal)
        #expect(!SelfSignedIdentity.Failure.certificateRejected.isKeychainRefusal)
        #expect(!SelfSignedIdentity.Failure.keyGeneration("x").isKeychainRefusal)
    }
}
