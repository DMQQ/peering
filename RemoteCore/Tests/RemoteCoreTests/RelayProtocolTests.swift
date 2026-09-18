import Foundation
import Testing

@testable import RemoteCore

@Suite("Relay protocol")
struct RelayProtocolTests {
    @Test("a Mac registration uses peeringd's public JSON contract")
    func hostRegistration() throws {
        let message = RelayClientMessage.registerHost(
            deviceID: "mac-1",
            name: "Studio",
            protocolVersion: 3
        )

        let encoded = try RelayMessageCodec.encode(message)

        #expect(String(decoding: encoded, as: UTF8.self) ==
            #"{"deviceId":"mac-1","name":"Studio","protocolVersion":3,"type":"registerHost"}"#)
    }

    @Test("a ready session exposes endpoints and raw routing tokens")
    func readySession() throws {
        let json = #"{"type":"sessionReady","controlHost":"relay.getpeering.app","controlPort":20190,"videoHost":"relay.getpeering.app","videoPort":30190,"controlToken":"000102030405060708090a0b0c0d0e0f","videoToken":"fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0"}"#

        let message = try RelayMessageCodec.decode(
            RelayServerMessage.self,
            from: Data(json.utf8)
        )

        #expect(message == .sessionReady(RelaySession(
            controlHost: "relay.getpeering.app",
            controlPort: 20_190,
            videoHost: "relay.getpeering.app",
            videoPort: 30_190,
            controlToken: Data(0...15),
            videoToken: Data((240...255).reversed())
        )))
    }

    @Test("an iPhone connection request uses the paired Mac and phone IDs")
    func connectRequest() throws {
        let encoded = try RelayMessageCodec.encode(RelayClientMessage.connectToHost(
            hostID: "mac-1",
            clientID: "phone-1",
            protocolVersion: 3
        ))

        #expect(String(decoding: encoded, as: UTF8.self) ==
            #"{"clientId":"phone-1","hostId":"mac-1","protocolVersion":3,"type":"connectToHost"}"#)
    }

    /// The plan is the client's claim, and peeringd reads it by name: `free`, `relay`, `plus`,
    /// `pro`. Anything else, including this field being absent, is the free allowance on the relay
    /// side, so a typo here costs a subscriber their allowance rather than granting anything.
    @Test("a connection request states the plan the client claims")
    func connectRequestNamesItsPlan() throws {
        let encoded = try RelayMessageCodec.encode(RelayClientMessage.connectToHost(
            hostID: "mac-1",
            clientID: "phone-1",
            protocolVersion: 3,
            plan: "relay"
        ))

        #expect(String(decoding: encoded, as: UTF8.self) ==
            #"{"clientId":"phone-1","hostId":"mac-1","plan":"relay","protocolVersion":3,"type":"connectToHost"}"#)
    }

    /// The receipt travels beside the claim rather than instead of it, and the relay decides which
    /// of the two it believes. The field name is Apple's — `Transaction.jwsRepresentation` — so that
    /// what is sent here and what is read there are recognisably the same document.
    @Test("a connection request carries the signed transaction beside the plan")
    func connectRequestCarriesItsReceipt() throws {
        let encoded = try RelayMessageCodec.encode(RelayClientMessage.connectToHost(
            hostID: "mac-1",
            clientID: "phone-1",
            protocolVersion: 3,
            plan: "pro",
            jwsRepresentation: "eyJhbGci.eyJidW5kbGUi.c2ln"
        ))

        #expect(String(decoding: encoded, as: UTF8.self) ==
            #"{"clientId":"phone-1","hostId":"mac-1","jwsRepresentation":"eyJhbGci.eyJidW5kbGUi.c2ln","plan":"pro","protocolVersion":3,"type":"connectToHost"}"#)
    }

    /// Absent rather than empty when there is nothing to prove. The relay reads a field that is not
    /// there as "no receipt" and an empty string as a receipt that is malformed; they end in the
    /// same allowance, but only one of them is what the app means, and the relay's log says which.
    @Test("a connection request with nothing to prove leaves the receipt out")
    func connectRequestOmitsAnAbsentReceipt() throws {
        let encoded = try RelayMessageCodec.encode(RelayClientMessage.connectToHost(
            hostID: "mac-1",
            clientID: "phone-1",
            protocolVersion: 3,
            plan: "free"
        ))

        #expect(String(decoding: encoded, as: UTF8.self) ==
            #"{"clientId":"phone-1","hostId":"mac-1","plan":"free","protocolVersion":3,"type":"connectToHost"}"#)
    }

    @Test("signalling JSON travels in a WebSocket text frame")
    func signallingUsesTextFrames() throws {
        switch try RelaySignallingConnection.wireMessage(.ping) {
        case .string(let text):
            #expect(text == #"{"type":"ping"}"#)
        case .data:
            Issue.record("peeringd ignores binary WebSocket frames")
        @unknown default:
            Issue.record("unexpected WebSocket message representation")
        }
    }

    @Test("registered reply accepts peeringd's TTL spelling")
    func registeredReply() throws {
        let json = #"{"type":"registered","sessionTtlSeconds":300}"#
        let decoded = try RelayMessageCodec.decode(
            RelayServerMessage.self,
            from: Data(json.utf8)
        )
        #expect(decoded == .registered(sessionTTLSeconds: 300))
    }

    /// The introduction, asked for. Spelled out rather than round-tripped, because the other end of
    /// this contract is Rust: a rename on either side is a silent break at runtime rather than a
    /// compile error here, which is exactly the kind of failure a literal pins.
    @Test("asking where the peer is sends the asker's own token, in the relay's hex")
    func peerAddressRequest() throws {
        let message = RelayClientMessage.requestPeerAddress(
            videoToken: Data(repeating: 0xcd, count: 16)
        )

        let encoded = try RelayMessageCodec.encode(message)

        #expect(String(decoding: encoded, as: UTF8.self) ==
            #"{"type":"requestPeerAddress","videoToken":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"}"#)
    }

    /// A leading zero is the one byte a hex encoder can silently drop, and what that produces is a
    /// thirty-one character token the relay refuses by length alone — a session that never opens,
    /// from a fault that looks like nothing at all in a diff.
    @Test("a token whose first byte is zero keeps both of its digits")
    func peerAddressRequestKeepsLeadingZeros() throws {
        let message = RelayClientMessage.requestPeerAddress(
            videoToken: Data([0x00] + Array(repeating: 0xab, count: 15))
        )

        let encoded = try RelayMessageCodec.encode(message)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(text.contains("\"videoToken\":\"00" + String(repeating: "ab", count: 15) + "\""))
    }

    @Test("an address from the relay decodes into the peer's host and port")
    func peerAddressReply() throws {
        let json = #"{"type":"peerAddress","host":"203.0.113.7","port":51234}"#

        let decoded = try RelayMessageCodec.decode(RelayServerMessage.self, from: Data(json.utf8))

        #expect(decoded == .peerAddress(RelayPeerAddress(host: "203.0.113.7", port: 51234)))
    }

    /// An IPv6 literal is just a host string to this codec, and the relay does not bracket it. This
    /// pins that the two ends agree — the alternative is finding out when the first v6 user cannot
    /// be reached, which is a bug with no symptom at all on an IPv4 machine.
    @Test("an IPv6 address survives as the relay spells it")
    func peerAddressIPv6() throws {
        let json = #"{"type":"peerAddress","host":"2001:db8::1","port":443}"#

        let decoded = try RelayMessageCodec.decode(RelayServerMessage.self, from: Data(json.utf8))

        #expect(decoded == .peerAddress(RelayPeerAddress(host: "2001:db8::1", port: 443)))
    }

    /// The "not yet" answer arrives as an error, so it is worth pinning that it is a code the caller
    /// can tell apart from a refusal — the two lead to opposite decisions, one being to ask again
    /// and the other to give up on the relay entirely.
    @Test("the unknown-peer answer is a code, not just a failure")
    func peerAddressUnknown() throws {
        let json = #"{"type":"error","code":"peerAddressUnknown","message":"not yet"}"#

        let decoded = try RelayMessageCodec.decode(RelayServerMessage.self, from: Data(json.utf8))

        #expect(decoded == .error(code: "peerAddressUnknown", message: "not yet"))
    }
}
