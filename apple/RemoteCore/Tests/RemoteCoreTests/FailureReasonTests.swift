import Foundation
import Testing
@testable import RemoteCore

struct FailureReasonTests {
    @Test func everyHandshakeFailureHasItsOwnOrSharedReason() {
        #expect(ClientSession.Failure.busy.reason == .busy)
        #expect(ClientSession.Failure.protocolMismatch(client: 1, host: 2).reason == .protocolMismatch)
        #expect(ClientSession.Failure.pinMismatch(hostID: "a").reason == .pinMismatch)
        #expect(ClientSession.Failure.noPinOnFile(hostID: "a").reason == .noPinOnFile)
        #expect(ClientSession.Failure.hostIDMismatch(dialled: "a", answered: "b").reason == .hostIDMismatch)
        #expect(ClientSession.Failure.identity("x").reason == .identity)
        #expect(ClientSession.Failure.commitmentMismatch.reason == .handshake)
        #expect(ClientSession.Failure.noServerKey.reason == .handshake)
    }

    @Test func aTransportFailureKeepsItsKind() {
        #expect(ClientSession.FailureReason(ClientConnection.Failure.timedOut(10)) == .timedOut)
        #expect(ClientSession.FailureReason(ClientConnection.Failure.hostClosed) == .hostClosed)
        #expect(ClientSession.FailureReason(ClientConnection.Failure.refused("no")) == .refused)
        #expect(ClientSession.FailureReason(ClientConnection.Failure.transport("reset")) == .transport)
    }

    @Test func anUnknownErrorIsOther() {
        struct Unknown: Error {}
        #expect(ClientSession.FailureReason(Unknown()) == .other)
    }

    @Test func aReasonCarriesNoMacNameOrAddress() {
        let failure = ClientSession.Failure.hostIDMismatch(dialled: "secret-mac", answered: "10.0.0.5")
        #expect(!failure.reason.rawValue.contains("secret-mac"))
        #expect(!failure.reason.rawValue.contains("10.0.0.5"))
    }
}
