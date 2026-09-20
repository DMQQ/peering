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

    @Test("a proved registration carries all three fields")
    func provedRegistration() throws {
        let message = RelayClientMessage.registerHost(
            deviceID: "mac-1",
            name: "Studio",
            protocolVersion: 14,
            proof: RelayDeviceProof(publicKey: "04aa", signature: "3045", proofTime: 1_760_000_000)
        )

        let encoded = try RelayMessageCodec.encode(message)
        let text = String(decoding: encoded, as: UTF8.self)

        // Every field by name, because the relay reads them by name and a rename here is a
        // registration that silently stops proving anything.
        for fragment in [
            #""type":"registerHost""#, #""deviceId":"mac-1""#, #""publicKey":"04aa""#,
            #""proof":"3045""#, #""proofTime":1760000000"#,
        ] {
            #expect(text.contains(fragment), "\(fragment) should be on the wire")
        }
    }

    /// **The string both ends have to build identically**, and the reason this test spells it out
    /// rather than calling the function twice: a signature is over bytes, so two ends that compose
    /// "what was signed" differently produce a proof that fails for a reason nothing on either side
    /// can see. The relay pins the same literal in `device_proof::tests`, and these two are meant
    /// to be read side by side.
    @Test("the signed payload is the same string the relay builds")
    func proofPayload() {
        let payload = RelayDeviceProof.payload(
            deviceID: "8B88D893-55BD-4F68-AF3F-E81D885A50A7",
            proofTime: 1_760_000_000
        )

        #expect(String(decoding: payload, as: UTF8.self) ==
            "peeringd-host-registration-v1\n8B88D893-55BD-4F68-AF3F-E81D885A50A7\n1760000000")
    }

    /// **The client's payload, pinned to the relay's spelling of it.** The two are written in two
    /// languages and neither can see the other, so this literal is the contract: `client_payload`
    /// in the relay's `device_proof.rs` has to produce exactly this string, tag and newlines and
    /// all, or every proof fails to verify and reads, from the relay, exactly like a client that
    /// sent none.
    @Test("the client payload is the string the relay builds")
    func clientPayloadMatchesTheRelay() {
        let payload = RelayDeviceProof.clientPayload(
            clientID: "A1B2",
            proofTime: 1_760_000_000
        )

        #expect(String(decoding: payload, as: UTF8.self) ==
            "peeringd-client-registration-v1\nA1B2\n1760000000")
    }

    /// And the two domains are different strings, which is the whole reason the tag is there: a
    /// registration signed for a Mac must not be presentable as one from a phone, and the fields
    /// have the same names on the wire.
    @Test("a host registration and a client registration are different strings")
    func theTwoProofDomainsDiffer() {
        let host = RelayDeviceProof.payload(deviceID: "A1B2", proofTime: 1_760_000_000)
        let client = RelayDeviceProof.clientPayload(clientID: "A1B2", proofTime: 1_760_000_000)

        #expect(host != client)
    }

    /// The connect request carries the proof under the same three field names the Mac's
    /// registration uses, and leaves all three out when there is none: the relay's spelling of
    /// "no proof" is the fields being absent.
    @Test("a connection request carries the client's proof, or nothing")
    func connectRequestCarriesTheClientProof() throws {
        let proved = try RelayMessageCodec.encode(RelayClientMessage.connectToHost(
            hostID: "mac-1",
            clientID: "phone-1",
            protocolVersion: 16,
            clientProof: RelayDeviceProof(
                publicKey: "04aa",
                signature: "3045",
                proofTime: 1_760_000_000
            )
        ))
        let text = String(decoding: proved, as: UTF8.self)

        #expect(text.contains("\"publicKey\":\"04aa\""))
        #expect(text.contains("\"proof\":\"3045\""))
        #expect(text.contains("\"proofTime\":1760000000"))

        let unproved = try RelayMessageCodec.encode(RelayClientMessage.connectToHost(
            hostID: "mac-1",
            clientID: "phone-1",
            protocolVersion: 16
        ))
        let plain = String(decoding: unproved, as: UTF8.self)

        #expect(!plain.contains("publicKey"))
        #expect(!plain.contains("\"proof\""))
        #expect(!plain.contains("proofTime"))
    }

    /// A device id cannot contain a newline and a time cannot contain anything but digits, so no
    /// two different registrations can sign the same bytes. That is what makes the delimiter safe
    /// rather than clever.
    @Test("the payload separates its fields so two registrations cannot collide")
    func proofPayloadIsUnambiguous() {
        let one = RelayDeviceProof.payload(deviceID: "a\n1", proofTime: 2)
        let two = RelayDeviceProof.payload(deviceID: "a", proofTime: 1)
        #expect(String(decoding: one, as: UTF8.self) != String(decoding: two, as: UTF8.self))
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

    /// **The token decoder's length check has to be in the units the loop moves in.** It asked for
    /// thirty-two *bytes* and then walked thirty-two *characters*, so a string that was thirty-two
    /// bytes but fewer characters made the sixteenth step ask for an index past the end. That is a
    /// trap, not a thrown error, and it is reachable from whatever the relay sends: this test would
    /// have crashed the suite rather than failed it.
    @Test("a token of thirty-two bytes but fewer characters is refused, not crashed on")
    func tokenWithMultibyteCharactersIsRefused() throws {
        // Twenty-eight digits and one four-byte character: thirty-two bytes, twenty-nine
        // characters, which is exactly the shape that used to walk off the end.
        let token = String(repeating: "a", count: 28) + "💥"
        #expect(token.utf8.count == 32)
        #expect(token.count == 29)

        let json = """
            {"type":"sessionReady","controlHost":"relay.getpeering.app","controlPort":20190,\
            "videoHost":"relay.getpeering.app","videoPort":30190,"controlToken":"\(token)",\
            "videoToken":"fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0"}
            """

        #expect(throws: RelayProtocolError.invalidToken) {
            try RelayMessageCodec.decode(RelayServerMessage.self, from: Data(json.utf8))
        }
    }

    /// A token that is the right length and the wrong alphabet. `UInt8(_:radix:)` accepts a
    /// leading `+`, so sixteen `+1` pairs would otherwise decode to sixteen one-bytes and be
    /// handed on as though the relay had sent them.
    @Test("a token of plus signs is refused rather than parsed as numbers")
    func tokenWithSignsIsRefused() throws {
        let token = String(repeating: "+1", count: 16)
        #expect(token.count == 32)

        let json = """
            {"type":"sessionReady","controlHost":"relay.getpeering.app","controlPort":20190,\
            "videoHost":"relay.getpeering.app","videoPort":30190,"controlToken":"\(token)",\
            "videoToken":"fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0"}
            """

        #expect(throws: RelayProtocolError.invalidToken) {
            try RelayMessageCodec.decode(RelayServerMessage.self, from: Data(json.utf8))
        }
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

    @Test("a presence question names the Mac it is about")
    func presenceQuestion() throws {
        let encoded = try RelayMessageCodec.encode(
            RelayClientMessage.hostPresence(hostID: "8B88D893")
        )

        #expect(String(decoding: encoded, as: UTF8.self) ==
            #"{"hostId":"8B88D893","type":"hostPresence"}"#)
    }

    /// **The two answers are both answers.** `online: false` is the relay stating a fact, and it
    /// has to arrive as a decoded value rather than as an error, because the screen draws it as
    /// one and the absence of an answer as something else entirely.
    @Test("both presence answers decode, and neither is an error")
    func presenceAnswers() throws {
        let online = try RelayMessageCodec.decode(
            RelayServerMessage.self,
            from: Data(#"{"type":"hostPresence","hostId":"mac-1","online":true}"#.utf8)
        )
        let offline = try RelayMessageCodec.decode(
            RelayServerMessage.self,
            from: Data(#"{"type":"hostPresence","hostId":"mac-1","online":false}"#.utf8)
        )

        #expect(online == .hostPresence(deviceID: "mac-1", online: true))
        #expect(offline == .hostPresence(deviceID: "mac-1", online: false))
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
