import Foundation
import Testing
@testable import RemoteCore

struct PairingProofTests {
    private func transcript(serverNonce: UInt8 = 4) -> PairingTranscript {
        PairingTranscript(
            protocolVersion: ProtocolInfo.version,
            clientID: "phone",
            serverID: "mac",
            clientEphemeralPublicKey: Data([1]),
            serverEphemeralPublicKey: Data([2]),
            clientNonce: Data([3]),
            serverNonce: Data([serverNonce]),
            serverIdentityPublicKey: Data([5])
        )
    }

    @Test func aProofFromTheRightSecretVerifies() {
        let secret = Data(repeating: 7, count: 16)
        let proof = PairingSAS.proof(secret: secret, transcript: transcript())
        #expect(PairingSAS.verifyProof(proof, secret: secret, transcript: transcript()))
    }

    @Test func aProofFromAnotherSecretOrTranscriptFails() {
        let secret = Data(repeating: 7, count: 16)
        let proof = PairingSAS.proof(secret: secret, transcript: transcript())
        #expect(!PairingSAS.verifyProof(proof, secret: Data(repeating: 8, count: 16), transcript: transcript()))
        #expect(!PairingSAS.verifyProof(proof, secret: secret, transcript: transcript(serverNonce: 9)))
    }

    @Test func theSecretSurvivesTheQRCode() {
        let secret = Data((0..<16).map { UInt8($0 * 17) })
        let payload = PairingPayload.encode(code: "123456", secret: secret)
        #expect(PairingPayload.code(from: payload) == "123456")
        #expect(PairingPayload.secret(from: payload) == secret)
        #expect(PairingPayload.secret(from: "123456") == nil)
    }
}
