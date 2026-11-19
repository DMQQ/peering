import Foundation
import Testing

@testable import RemoteCore

extension ClientPairingTests {
    /// Nested so the parent's `.serialized` covers the Keychain keys these mint.
    @Suite("One QUIC connection moving between the relay and a direct path")
    struct QuicMigrationTests {
        @Test("a relayed connection moves onto a direct path, keeps carrying frames, and moves back")
        func movesToDirectAndBack() async throws {
            try await withTestEnds { client, mac in
                let relay = try TokenRelay()
                defer { relay.stop() }
                let relayAddress = QuicAddress(host: "127.0.0.1", port: relay.port)!
                let macLink = try QuicFrameLink.listen(port: 0, relay: .init(address: relayAddress, token: TokenRelay.token(1)), configuration: QuicConfiguration(identity: mac), label: "test.mac")
                defer { macLink.close() }
                macLink.onFrame = { [weak macLink] frame in macLink?.send(frame) }
                let macEvents = PathEvents()
                macLink.onPathEvent = { macEvents.add($0) }

                let phone = try QuicFrameLink.dial(relayAddress, relay: .init(address: relayAddress, token: TokenRelay.token(0)), configuration: QuicConfiguration(identity: client), label: "test.phone")
                defer { phone.close() }
                let received = Received()
                phone.onFrame = { received.add($0) }
                let phoneEvents = PathEvents()
                phone.onPathEvent = { phoneEvents.add($0) }

                let first = Frame(kind: .command, payload: Data("via relay".utf8))
                phone.send(first)
                #expect(await received.wait { $0.contains(first) })

                let macPort = try #require(macLink.localPort)
                let direct = try #require(QuicAddress(host: "127.0.0.1", port: macPort))
                phone.onPath { context in
                    guard let context else { return }
                    context.connection.probePath(local: context.local, peer: direct)
                }
                #expect(await phoneEvents.wait { $0.contains { if case .validated(_, direct) = $0 { true } else { false } } })
                phone.onPath { context in
                    guard let context else { return }
                    context.connection.migrate(local: context.local, peer: direct)
                }

                let relayedBefore = relay.forwarded
                let second = Frame(kind: .command, payload: Data("direct".utf8))
                phone.send(second)
                #expect(await received.wait { $0.contains(second) })
                #expect(await macEvents.wait { $0.contains { if case .peerMigrated(_, let peer) = $0 { peer != relayAddress } else { false } } })
                // A handful of packets may still be in flight through the relay when the move happens.
                #expect(relay.forwarded - relayedBefore < 10)

                phone.onPath { context in
                    guard let context else { return }
                    context.connection.migrate(local: context.local, peer: relayAddress)
                }
                let third = Frame(kind: .command, payload: Data("relay again".utf8))
                phone.send(third)
                #expect(await received.wait { $0.contains(third) })
                #expect(await macEvents.wait { $0.contains { if case .peerMigrated(_, relayAddress) = $0 { true } else { false } } })
            }
        }
    }
}

final class PathEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [QuicConnection.PathEvent] = []

    func add(_ event: QuicConnection.PathEvent) { lock.withLock { events.append(event) } }

    func wait(seconds: Double = 5, until condition: ([QuicConnection.PathEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if lock.withLock({ condition(events) }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { condition(events) }
    }
}
