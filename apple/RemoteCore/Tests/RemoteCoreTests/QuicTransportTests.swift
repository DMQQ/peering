import Foundation
import Testing

@testable import RemoteCore

extension ClientPairingTests {
    /// Nested so the parent's `.serialized` covers the Keychain keys these mint.
    @Suite("A session's connection over QUIC")
    struct QuicTransportTests {
        private static func relaySession(port: UInt16, token: Data) -> RelaySession {
            RelaySession(controlHost: "127.0.0.1", controlPort: 1, videoHost: "127.0.0.1", videoPort: port, controlToken: Data(count: 16), videoToken: token)
        }

        private static func pin(of identity: SelfSignedIdentity) -> Data? {
            SecCertificateCreateWithData(nil, identity.certificateDER as CFData).flatMap(SPKI.bytes(of:))
        }

        /// The Mac's end behind the fake relay, echoing every frame back.
        private static func echoingMac(_ identity: SelfSignedIdentity, relay: TokenRelay) throws -> QuicFrameLink {
            let link = try QuicFrameLink.listen(
                port: 0,
                relay: .init(address: QuicAddress(host: "127.0.0.1", port: relay.port)!, token: TokenRelay.token(1)),
                configuration: QuicConfiguration(identity: identity),
                label: "test.mac"
            )
            link.onFrame = { [weak link] frame in link?.send(frame) }
            return link
        }

        @Test("the phone connects through the relay, learns the Mac's key, and frames go both ways")
        func connectsAndExchangesFrames() async throws {
            try await withTestEnds { client, mac in
                let relay = try TokenRelay()
                defer { relay.stop() }
                let macLink = try Self.echoingMac(mac, relay: relay)
                defer { macLink.close() }

                let connection = ClientConnection(label: "test.phone")
                let received = Received()
                connection.onFrame = { received.add($0) }
                try await connection.connectQuic(relay: Self.relaySession(port: relay.port, token: TokenRelay.token(0)), identity: client, pinnedServerKey: Self.pin(of: mac), timeout: 5)
                #expect(connection.observedServerKey == Self.pin(of: mac))
                #expect(connection.negotiatedTLSVersion == "QUIC (TLS 1.3)")

                let frame = Frame(kind: .command, payload: Data("hello".utf8))
                connection.send(frame)
                #expect(await received.wait { $0.contains(frame) })
                connection.cancel()
            }
        }

        @Test("a Mac whose key is not the pinned one is refused")
        func refusesAnotherKey() async throws {
            try await withTestEnds { client, mac in
                let relay = try TokenRelay()
                defer { relay.stop() }
                let macLink = try Self.echoingMac(mac, relay: relay)
                defer { macLink.close() }

                let connection = ClientConnection(label: "test.phone")
                await #expect(throws: ClientConnection.Failure.self) {
                    try await connection.connectQuic(relay: Self.relaySession(port: relay.port, token: TokenRelay.token(0)), identity: client, pinnedServerKey: Data(repeating: 4, count: 65), timeout: 5)
                }
            }
        }

        @Test("with nobody behind the relay the connect gives up at its timeout")
        func timesOutWithNoMac() async throws {
            try await withTestEnds { client, _ in
                let relay = try TokenRelay()
                defer { relay.stop() }
                let connection = ClientConnection(label: "test.phone")
                await #expect(throws: ClientConnection.Failure.timedOut(1)) {
                    try await connection.connectQuic(relay: Self.relaySession(port: relay.port, token: TokenRelay.token(0)), identity: client, pinnedServerKey: nil, timeout: 1)
                }
            }
        }

        @Test("the Mac ending the session reaches the phone as a close")
        func macCloseReachesThePhone() async throws {
            try await withTestEnds { client, mac in
                let relay = try TokenRelay()
                defer { relay.stop() }
                let macLink = try Self.echoingMac(mac, relay: relay)

                let connection = ClientConnection(label: "test.phone")
                let closed = Received()
                connection.onClose = { _ in closed.add(Frame(kind: .error)) }
                try await connection.connectQuic(relay: Self.relaySession(port: relay.port, token: TokenRelay.token(0)), identity: client, pinnedServerKey: nil, timeout: 5)
                macLink.close(reason: "test")
                #expect(await closed.wait { !$0.isEmpty })
            }
        }

        @Test("a frame sent before the connection has its first packet is delivered, not dropped")
        func earlyFramesAreKept() async throws {
            try await withTestEnds { client, mac in
                let relay = try TokenRelay()
                defer { relay.stop() }
                let macLink = try Self.echoingMac(mac, relay: relay)
                defer { macLink.close() }
                let relayAddress = QuicAddress(host: "127.0.0.1", port: relay.port)!
                let phone = try QuicFrameLink.dial(relayAddress, relay: .init(address: relayAddress, token: TokenRelay.token(0)), configuration: QuicConfiguration(identity: client), label: "test.phone")
                defer { phone.close() }
                let received = Received()
                phone.onFrame = { received.add($0) }
                let early = Frame(kind: .command, payload: Data("early".utf8))
                phone.send(early)
                #expect(await received.wait { $0.contains(early) })
            }
        }
    }
}

/// Frames gathered from a callback thread, read by the test.
final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Frame] = []

    func add(_ frame: Frame) { lock.withLock { frames.append(frame) } }

    func wait(seconds: Double = 5, until condition: ([Frame]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if lock.withLock({ condition(frames) }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { condition(frames) }
    }
}
