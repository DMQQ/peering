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

        // Every field by name: the relay reads them by name.
        for fragment in [
            #""type":"registerHost""#, #""deviceId":"mac-1""#, #""publicKey":"04aa""#,
            #""proof":"3045""#, #""proofTime":1760000000"#,
        ] {
            #expect(text.contains(fragment), "\(fragment) should be on the wire")
        }
    }

    /// Spelled out, not computed twice: both ends must build the signed bytes identically, and the relay pins the same literal in `device_proof::tests`.
    @Test("the signed payload is the same string the relay builds")
    func proofPayload() {
        let payload = RelayDeviceProof.payload(
            deviceID: "8B88D893-55BD-4F68-AF3F-E81D885A50A7",
            proofTime: 1_760_000_000
        )

        #expect(String(decoding: payload, as: UTF8.self) ==
            "peeringd-host-registration-v1\n8B88D893-55BD-4F68-AF3F-E81D885A50A7\n1760000000")
    }

    /// Pinned to the relay's `client_payload` in `device_proof.rs`: any difference makes every proof fail, reading like a client that sent none.
    @Test("the client payload is the string the relay builds")
    func clientPayloadMatchesTheRelay() {
        let payload = RelayDeviceProof.clientPayload(
            clientID: "A1B2",
            proofTime: 1_760_000_000
        )

        #expect(String(decoding: payload, as: UTF8.self) ==
            "peeringd-client-registration-v1\nA1B2\n1760000000")
    }

    /// The tag separates the domains: a Mac registration must not be presentable as a phone's.
    @Test("a host registration and a client registration are different strings")
    func theTwoProofDomainsDiffer() {
        let host = RelayDeviceProof.payload(deviceID: "A1B2", proofTime: 1_760_000_000)
        let client = RelayDeviceProof.clientPayload(clientID: "A1B2", proofTime: 1_760_000_000)

        #expect(host != client)
    }

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

    /// Ids cannot contain a newline and times only digits, so no two registrations sign the same bytes.
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

    @Test("a ready session carries the relay's remaining seconds when it sends them")
    func readySessionRemainingSeconds() throws {
        let json = #"{"type":"sessionReady","controlHost":"h","controlPort":1,"videoHost":"h","videoPort":2,"controlToken":"000102030405060708090a0b0c0d0e0f","videoToken":"fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0","remainingSeconds":1703}"#

        let message = try RelayMessageCodec.decode(RelayServerMessage.self, from: Data(json.utf8))

        guard case .sessionReady(let session) = message else {
            Issue.record("not a sessionReady")
            return
        }
        #expect(session.remainingSeconds == 1_703)
    }

    @Test("a ready session from an older relay has no remaining seconds")
    func readySessionWithoutRemainingSeconds() throws {
        let json = #"{"type":"sessionReady","controlHost":"h","controlPort":1,"videoHost":"h","videoPort":2,"controlToken":"000102030405060708090a0b0c0d0e0f","videoToken":"fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0"}"#

        let message = try RelayMessageCodec.decode(RelayServerMessage.self, from: Data(json.utf8))

        guard case .sessionReady(let session) = message else {
            Issue.record("not a sessionReady")
            return
        }
        #expect(session.remainingSeconds == nil)
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

    /// The plan is a claim: anything unknown or absent is the free allowance on the relay.
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

    /// The receipt travels beside the claim; the relay decides which it believes.
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

    /// Absent rather than empty: the relay reads an empty string as a malformed receipt.
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

    /// Spelled out because the other end is Rust: a rename is a silent runtime break, not a compile error.
    @Test("asking where the peer is sends the asker's own token, in the relay's hex")
    func peerAddressRequest() throws {
        let message = RelayClientMessage.requestPeerAddress(
            videoToken: Data(repeating: 0xcd, count: 16)
        )

        let encoded = try RelayMessageCodec.encode(message)

        #expect(String(decoding: encoded, as: UTF8.self) ==
            #"{"type":"requestPeerAddress","videoToken":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"}"#)
    }

    /// A hex encoder can drop a leading zero, giving a 31-character token the relay refuses by length.
    @Test("a token whose first byte is zero keeps both of its digits")
    func peerAddressRequestKeepsLeadingZeros() throws {
        let message = RelayClientMessage.requestPeerAddress(
            videoToken: Data([0x00] + Array(repeating: 0xab, count: 15))
        )

        let encoded = try RelayMessageCodec.encode(message)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(text.contains("\"videoToken\":\"00" + String(repeating: "ab", count: 15) + "\""))
    }

    /// The length check must be in the units the loop moves in: 32 bytes but fewer characters walked off the end and trapped.
    @Test("a token of thirty-two bytes but fewer characters is refused, not crashed on")
    func tokenWithMultibyteCharactersIsRefused() throws {
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

    /// `UInt8(_:radix:)` accepts a leading `+`, so `+1` pairs would otherwise decode as one-bytes.
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

    /// An IPv6 literal is an unbracketed host string to this codec; the ends must agree.
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

    /// `online: false` is a fact and must decode as a value, not an error.
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

    /// The not-yet answer must be a code distinguishable from a refusal: one means ask again, the other give up on the relay.
    @Test("the unknown-peer answer is a code, not just a failure")
    func peerAddressUnknown() throws {
        let json = #"{"type":"error","code":"peerAddressUnknown","message":"not yet"}"#

        let decoded = try RelayMessageCodec.decode(RelayServerMessage.self, from: Data(json.utf8))

        #expect(decoded == .error(code: "peerAddressUnknown", message: "not yet"))
    }

    @Test("a push for an approval names its category and what it answers")
    func notifyDeviceWithAnAction() throws {
        let message = RelayClientMessage.notifyDevice(
            token: "ab",
            title: "T",
            body: "B",
            action: RelayPushAction(category: "peering.agent.approval.tool", sessionID: "S", approvalID: "A")
        )

        let encoded = String(decoding: try RelayMessageCodec.encode(message), as: UTF8.self)

        #expect(encoded.contains(#""category":"peering.agent.approval.tool""#))
        #expect(encoded.contains(#""sessionId":"S""#))
        #expect(encoded.contains(#""approvalId":"A""#))
    }

    @Test("a question with its own choices sends them for the phone to make buttons")
    func notifyDeviceWithAnswers() throws {
        let action = RelayPushAction(category: "peering.agent.approval.open", sessionID: "S", approvalID: "A", answers: ["Red", "Blue"])
        let encoded = String(
            decoding: try RelayMessageCodec.encode(RelayClientMessage.notifyDevice(token: "ab", title: "T", body: "B", action: action)),
            as: UTF8.self
        )

        #expect(encoded.contains(#""options":["Red","Blue"]"#))
    }

    @Test("a push without an action is the message it always was")
    func notifyDeviceWithoutAnAction() throws {
        let encoded = String(
            decoding: try RelayMessageCodec.encode(RelayClientMessage.notifyDevice(token: "ab", title: "T", body: "B")),
            as: UTF8.self
        )

        #expect(!encoded.contains("category"))
        #expect(!encoded.contains("approvalId"))
    }
}

@Suite("Relay referrals")
struct RelayReferralTests {
    private let proof = RelayDeviceProof(publicKey: "04aa", signature: "3045", proofTime: 1_760_000_000)

    @Test("a redeem request names the code and carries the whole proof")
    func redeemRequest() throws {
        let message = RelayClientMessage.redeemReferral(clientID: "phone-1", code: "ABCD-EFGH", proof: proof)

        let text = String(decoding: try RelayMessageCodec.encode(message), as: UTF8.self)

        for fragment in [
            #""type":"redeemReferral""#, #""clientId":"phone-1""#, #""code":"ABCD-EFGH""#,
            #""publicKey":"04aa""#, #""proof":"3045""#, #""proofTime":1760000000"#,
        ] {
            #expect(text.contains(fragment), "\(fragment) should be on the wire")
        }
    }

    @Test("a status request has no code")
    func statusRequest() throws {
        let message = RelayClientMessage.referralStatus(clientID: "phone-1", proof: proof)

        let text = String(decoding: try RelayMessageCodec.encode(message), as: UTF8.self)

        #expect(text.contains(#""type":"referralStatus""#))
        #expect(!text.contains(#""code""#))
    }

    @Test("the signed text is the relay's, with the code exactly as typed")
    func signedText() {
        #expect(String(decoding: RelayDeviceProof.referralStatusPayload(clientID: "c", proofTime: 7), as: UTF8.self)
            == "peeringd-referral-v1\nstatus\nc\n7")
        #expect(String(decoding: RelayDeviceProof.redeemReferralPayload(clientID: "c", code: "ab cd", proofTime: 7), as: UTF8.self)
            == "peeringd-referral-v1\nredeem:ab cd\nc\n7")
    }

    @Test("a referral reply decodes with and without a running grant")
    func reply() throws {
        let running = #"{"type":"referral","code":"ABCDEFGH","bonusSeconds":1800,"bonusEndsAt":1760600000,"redeemed":true,"invitesEarned":2,"invitesMax":5}"#
        let idle = #"{"type":"referral","code":"ABCDEFGH","bonusSeconds":0,"bonusEndsAt":null,"redeemed":false,"invitesEarned":0,"invitesMax":5}"#

        let first = try RelayMessageCodec.decode(RelayServerMessage.self, from: Data(running.utf8))
        let second = try RelayMessageCodec.decode(RelayServerMessage.self, from: Data(idle.utf8))

        #expect(first == .referral(RelayReferral(
            code: "ABCDEFGH", bonusSeconds: 1800, bonusEndsAt: Date(timeIntervalSince1970: 1_760_600_000),
            redeemed: true, invitesEarned: 2, invitesMax: 5
        )))
        #expect(second == .referral(RelayReferral(
            code: "ABCDEFGH", bonusSeconds: 0, bonusEndsAt: nil, redeemed: false, invitesEarned: 0, invitesMax: 5
        )))
    }
}
