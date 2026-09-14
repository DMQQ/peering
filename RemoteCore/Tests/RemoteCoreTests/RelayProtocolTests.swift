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
        let json = #"{"type":"sessionReady","controlHost":"relay.dmqq.dev","controlPort":20190,"videoHost":"relay.dmqq.dev","videoPort":30190,"controlToken":"000102030405060708090a0b0c0d0e0f","videoToken":"fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0"}"#

        let message = try RelayMessageCodec.decode(
            RelayServerMessage.self,
            from: Data(json.utf8)
        )

        #expect(message == .sessionReady(RelaySession(
            controlHost: "relay.dmqq.dev",
            controlPort: 20_190,
            videoHost: "relay.dmqq.dev",
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
}
