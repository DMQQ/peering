import Foundation
import Testing

@testable import RemoteCore

@Suite("Handshake payloads")
struct HandshakeTests {
    @Test("clientHello round-trips")
    func clientHelloRoundTrip() throws {
        let hello = ClientHello(
            clientID: "client-1",
            clientName: "Damian's iPhone",
            protocolVersion: 1,
            wantsPairing: true
        )
        let decoded = try MessageCodec.decode(
            ClientHello.self,
            from: try MessageCodec.encode(hello)
        )
        #expect(decoded == hello)
    }

    @Test("serverHello round-trips")
    func serverHelloRoundTrip() throws {
        let hello = ServerHello(
            serverID: "server-1",
            hostName: "Damian's MacBook Pro",
            protocolVersion: 1,
            alreadyPaired: true,
            macAddresses: ["aa:bb:cc:dd:ee:ff", "01:23:45:67:89:ab"]
        )
        let decoded = try MessageCodec.decode(
            ServerHello.self,
            from: try MessageCodec.encode(hello)
        )
        #expect(decoded == hello)
    }

    @Test("an older serverHello without MAC addresses still decodes")
    func oldServerHelloStillDecodes() throws {
        let data = Data(#"{"serverID":"server-1","hostName":"Mac","protocolVersion":8,"alreadyPaired":true}"#.utf8)
        let hello = try MessageCodec.decode(ServerHello.self, from: data)

        #expect(hello.macAddresses == nil)
    }

    @Test("serverHello carries no public key")
    func serverHelloHasNoKeyField() throws {
        let hello = ServerHello(
            serverID: "server-1",
            hostName: "host",
            protocolVersion: 1,
            alreadyPaired: false
        )
        let data = try MessageCodec.encode(hello)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // A tripwire, not a formality. The host's public key must reach the client through
        // the TLS certificate, which the client verifies against its pin. If the key were
        // ever added here, the client would instead be trusting a value the peer simply
        // asserted, and pinning would be decorative. Adding a field should fail this test
        // so that possibility has to be considered deliberately.
        #expect(Set(object.keys) == ["serverID", "hostName", "protocolVersion", "alreadyPaired"])
    }

    @Test("pairing messages round-trip")
    func pairingRoundTrips() throws {
        let commitment = PairingCommit(commitment: Data(repeating: 0xAB, count: 32))
        #expect(
            try MessageCodec.decode(PairingCommit.self, from: try MessageCodec.encode(commitment))
                == commitment
        )

        let reveal = PairingReveal(
            ephemeralPublicKey: Data(repeating: 0x04, count: 65),
            nonce: Data(repeating: 0x11, count: 32)
        )
        #expect(
            try MessageCodec.decode(PairingReveal.self, from: try MessageCodec.encode(reveal))
                == reveal
        )

        let confirm = PairConfirm(accepted: true)
        #expect(
            try MessageCodec.decode(PairConfirm.self, from: try MessageCodec.encode(confirm))
                == confirm
        )

        let result = PairResult(accepted: false, reason: "codes did not match")
        #expect(
            try MessageCodec.decode(PairResult.self, from: try MessageCodec.encode(result))
                == result
        )
    }

    @Test("a pairResult without a reason round-trips")
    func pairResultWithoutReason() throws {
        // The success case omits `reason`, so the optional has to survive a round trip as
        // nil rather than arriving as an empty string the caller has to special-case.
        let result = PairResult(accepted: true)
        let decoded = try MessageCodec.decode(
            PairResult.self,
            from: try MessageCodec.encode(result)
        )
        #expect(decoded.reason == nil)
        #expect(decoded.accepted == true)
    }

    @Test("error payload round-trips")
    func errorRoundTrip() throws {
        let payload = ErrorPayload(code: "session", message: "protocol mismatch")
        #expect(
            try MessageCodec.decode(ErrorPayload.self, from: try MessageCodec.encode(payload))
                == payload
        )
    }

    @Test("a payload that is valid JSON of the wrong shape is rejected")
    func wrongShapeIsRejected() {
        // Decoding must fail loudly rather than silently producing a default value: a
        // half-understood handshake message is exactly the case that should stop a session.
        let notAHello = Data(#"{"unexpected": true}"#.utf8)
        #expect(throws: (any Error).self) {
            try MessageCodec.decode(ClientHello.self, from: notAHello)
        }
    }
}

@Suite("Device identity")
struct DeviceIdentityTests {
    /// A throwaway defaults domain, so tests never touch the real device identity.
    private func scratchDefaults() -> UserDefaults {
        let name = "pl.dmq.maccast.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test("mints an ID on first run and keeps it afterwards")
    func idIsStable() {
        let defaults = scratchDefaults()
        let first = DeviceIdentity.loadOrCreate(defaultName: "fallback", from: defaults)
        let second = DeviceIdentity.loadOrCreate(defaultName: "fallback", from: defaults)

        #expect(first.id == second.id)
        #expect(first.id.isEmpty == false)
    }

    @Test("uses the supplied default name")
    func usesDefaultName() {
        let identity = DeviceIdentity.loadOrCreate(
            defaultName: "Damians-MacBook-Pro",
            from: scratchDefaults()
        )
        #expect(identity.name == "Damians-MacBook-Pro")
    }

    @Test("a saved name outranks the default")
    func savedNameWins() {
        let defaults = scratchDefaults()
        DeviceIdentity(id: "x", name: "Renamed").saveName("Renamed", to: defaults)

        let identity = DeviceIdentity.loadOrCreate(defaultName: "fallback", from: defaults)
        #expect(identity.name == "Renamed")
    }

    @Test("two fresh stores get different IDs")
    func idsAreNotShared() {
        // The ID identifies one device, so two devices must not collide — and the only way
        // that happens is if something is accidentally reading shared storage.
        let a = DeviceIdentity.loadOrCreate(defaultName: "a", from: scratchDefaults())
        let b = DeviceIdentity.loadOrCreate(defaultName: "b", from: scratchDefaults())
        #expect(a.id != b.id)
    }
}
