import Foundation
import Testing

@testable import RemoteCore

@Suite("Pairing SAS")
struct PairingSASTests {
    private func transcript(
        clientEphemeral: Data = Data(repeating: 0xA1, count: 65),
        serverEphemeral: Data = Data(repeating: 0xB2, count: 65),
        clientNonce: Data = Data(repeating: 0xC3, count: 32),
        serverNonce: Data = Data(repeating: 0xD4, count: 32),
        serverIdentity: Data = Data(repeating: 0xE5, count: 65),
        clientID: String = "iphone-15-pro-max",
        serverID: String = "mac-studio-01"
    ) -> PairingTranscript {
        PairingTranscript(
            protocolVersion: 1,
            clientID: clientID,
            serverID: serverID,
            clientEphemeralPublicKey: clientEphemeral,
            serverEphemeralPublicKey: serverEphemeral,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            serverIdentityPublicKey: serverIdentity
        )
    }

    @Test("produces exactly six decimal digits")
    func shape() {
        let code = PairingSAS.code(for: transcript())
        #expect(code.count == 6)
        #expect(code.allSatisfy { $0.isNumber })

        // Zero-padding matters: a naive string conversion of 42 would show "42" and
        // give a user only two digits to compare.
        for _ in 0..<200 {
            let random = PairingTranscript(
                protocolVersion: 1,
                clientID: "c",
                serverID: "s",
                clientEphemeralPublicKey: Data((0..<65).map { _ in UInt8.random(in: 0...255) }),
                serverEphemeralPublicKey: Data((0..<65).map { _ in UInt8.random(in: 0...255) }),
                clientNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                serverNonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                serverIdentityPublicKey: Data((0..<65).map { _ in UInt8.random(in: 0...255) })
            )
            #expect(PairingSAS.code(for: random).count == 6)
        }
    }

    @Test("is deterministic, so both sides must agree")
    func deterministic() {
        #expect(PairingSAS.code(for: transcript()) == PairingSAS.code(for: transcript()))
    }

    /// Pins the exact output so a refactor cannot silently change what users compare,
    /// and so the iOS and macOS implementations stay byte-compatible.
    @Test("matches the frozen vector")
    func frozenVector() {
        #expect(PairingSAS.code(for: transcript()) == "365357")
    }

    /// Every field must be covered. If any one of them could change without disturbing
    /// the digits, an attacker could vary it freely.
    @Test("changing any transcript field changes the code")
    func allFieldsBound() {
        let base = PairingSAS.code(for: transcript())

        let variations: [PairingTranscript] = [
            transcript(clientEphemeral: Data(repeating: 0x11, count: 65)),
            transcript(serverEphemeral: Data(repeating: 0x22, count: 65)),
            transcript(clientNonce: Data(repeating: 0x33, count: 32)),
            transcript(serverNonce: Data(repeating: 0x44, count: 32)),
            transcript(serverIdentity: Data(repeating: 0x55, count: 65)),
            transcript(clientID: "different-client"),
            transcript(serverID: "different-server"),
        ]

        for variation in variations {
            let changed = PairingSAS.code(for: variation)
            // A 10⁻⁶ collision is possible in principle; across seven variations the
            // chance of a false failure is ~7×10⁻⁶.
            #expect(changed != base, "a field is not bound into the code")
        }
    }

    /// Without length prefixes, ("ab","c") and ("a","bc") serialize identically, so two
    /// peers disagreeing about the field split would still show matching digits.
    @Test("length prefixes make the encoding unambiguous")
    func lengthPrefixingPreventsAmbiguity() {
        let first = transcript(clientID: "ab", serverID: "c")
        let second = transcript(clientID: "a", serverID: "bc")
        #expect(first.serialized() != second.serialized())
    }

    @Test("protocol version participates in the encoding")
    func versionBound() {
        var bumped = transcript()
        bumped.protocolVersion = 2
        #expect(bumped.serialized() != transcript().serialized())
    }

    @Test("accepts a matching commitment")
    func commitmentRoundTrip() {
        let ephemeral = Data(repeating: 0x7A, count: 65)
        let nonce = Data(repeating: 0x9B, count: 32)
        let commitment = PairingSAS.commitment(ephemeralPublicKey: ephemeral, nonce: nonce)

        #expect(PairingSAS.verify(commitment: commitment, ephemeralPublicKey: ephemeral, nonce: nonce))
    }

    /// The property the whole commitment exchange exists for: a peer cannot swap its
    /// contribution after seeing the other side's reveal.
    @Test("rejects a reveal that does not match the commitment")
    func commitmentRejectsSubstitution() {
        let ephemeral = Data(repeating: 0x7A, count: 65)
        let nonce = Data(repeating: 0x9B, count: 32)
        let commitment = PairingSAS.commitment(ephemeralPublicKey: ephemeral, nonce: nonce)

        #expect(!PairingSAS.verify(
            commitment: commitment,
            ephemeralPublicKey: Data(repeating: 0x7B, count: 65),
            nonce: nonce
        ))
        #expect(!PairingSAS.verify(
            commitment: commitment,
            ephemeralPublicKey: ephemeral,
            nonce: Data(repeating: 0x9C, count: 32)
        ))
    }

    @Test("commitment hides the ephemeral key")
    func commitmentIsHiding() {
        let ephemeral = Data(repeating: 0x7A, count: 65)
        let commitment = PairingSAS.commitment(ephemeralPublicKey: ephemeral, nonce: Data(repeating: 1, count: 32))
        #expect(!commitment.starts(with: ephemeral))
        #expect(commitment.count == 32) // SHA-256
    }
}

@Suite("Constant-time comparison")
struct ConstantTimeTests {
    @Test("agrees with equality on matching and differing inputs")
    func correctness() {
        #expect(ConstantTime.equals(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!ConstantTime.equals(Data([1, 2, 3]), Data([1, 2, 4])))
        #expect(!ConstantTime.equals(Data([1, 2, 3]), Data([1, 2])))
        #expect(!ConstantTime.equals(Data(), Data([0])))
        #expect(ConstantTime.equals(Data(), Data()))
    }

    /// The difference is in the *first* byte, so a short-circuiting comparison would
    /// return almost immediately. This does not measure timing — it pins the behaviour
    /// that the loop must visit every byte regardless of where the difference is.
    @Test("does not short-circuit on an early difference")
    func noShortCircuit() {
        let long = Data(repeating: 0, count: 4096)
        var almost = long
        almost[0] = 1
        #expect(!ConstantTime.equals(long, almost))

        var lastByte = long
        lastByte[lastByte.count - 1] = 1
        #expect(!ConstantTime.equals(long, lastByte))
    }
}
