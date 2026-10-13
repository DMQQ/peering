import Foundation
import Testing

@testable import RemoteCore

private final class ScriptedLink: RelayPeerLink, @unchecked Sendable {
    enum Reply {
        case message(RelayServerMessage)
        case failure
        case stall
    }

    struct Dropped: Error {}

    // Guarded by `lock`.
    private let lock = NSLock()
    private var replies: [Reply]
    private var sentCount = 0
    private var cancelled = false
    private var stalled: CheckedContinuation<RelayServerMessage, any Error>?

    init(_ replies: [Reply]) { self.replies = replies }

    var requestsSent: Int { lock.withLock { sentCount } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func send(_ message: RelayClientMessage) async throws {
        lock.withLock { sentCount += 1 }
    }

    func receive() async throws -> RelayServerMessage {
        let next = lock.withLock { replies.isEmpty ? Reply.failure : replies.removeFirst() }
        switch next {
        case .message(let message): return message
        case .failure: throw Dropped()
        case .stall:
            return try await withCheckedThrowingContinuation { continuation in
                let alreadyCancelled = lock.withLock { () -> Bool in
                    if !cancelled { stalled = continuation }
                    return cancelled
                }
                if alreadyCancelled { continuation.resume(throwing: Dropped()) }
            }
        }
    }

    func cancel() {
        let waiting = lock.withLock { () -> CheckedContinuation<RelayServerMessage, any Error>? in
            cancelled = true
            defer { stalled = nil }
            return stalled
        }
        waiting?.resume(throwing: Dropped())
    }
}

private final class LinkSupply: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ScriptedLink]
    private(set) var handedOut: [ScriptedLink] = []

    init(_ links: [ScriptedLink]) { queue = links }

    func next() -> ScriptedLink {
        lock.withLock {
            let link = queue.removeFirst()
            handedOut.append(link)
            return link
        }
    }
}

@Suite("Looking up the peer's address")
struct RelayPeerLookupTests {
    private let token = Data(repeating: 7, count: 16)
    private let address = RelayPeerAddress(host: "203.0.113.9", port: 4242)

    private func lookup(_ supply: LinkSupply) -> RelayPeerLookup {
        RelayPeerLookup(open: { supply.next() })
    }

    @Test("many lookups share one socket")
    func reusesTheSocket() async throws {
        let link = ScriptedLink([
            .message(.error(code: "peerAddressUnknown", message: "")),
            .message(.pong),
            .message(.peerAddress(address)),
            .message(.peerAddress(address)),
        ])
        let supply = LinkSupply([link])
        let lookup = lookup(supply)

        #expect(try await lookup.address(videoToken: token) == nil)
        #expect(try await lookup.address(videoToken: token) == address)
        #expect(try await lookup.address(videoToken: token) == address)
        #expect(await lookup.socketsOpened == 1)
        #expect(link.requestsSent == 3)
    }

    @Test("a socket that fails is replaced on the next lookup, and only then")
    func reconnectsAfterAFailure() async throws {
        let broken = ScriptedLink([.failure])
        let fresh = ScriptedLink([.message(.peerAddress(address))])
        let supply = LinkSupply([broken, fresh])
        let lookup = lookup(supply)

        await #expect(throws: ScriptedLink.Dropped.self) { try await lookup.address(videoToken: token) }
        #expect(broken.wasCancelled)
        #expect(await lookup.socketsOpened == 1)

        #expect(try await lookup.address(videoToken: token) == address)
        #expect(await lookup.socketsOpened == 2)
    }

    @Test("a refusal closes the socket and surfaces the relay's code")
    func refusalIsSurfaced() async {
        let link = ScriptedLink([.message(.error(code: "invalid", message: "bad token"))])
        let lookup = lookup(LinkSupply([link]))
        await #expect(throws: RelaySignallingError.refused(code: "invalid", message: "bad token")) {
            try await lookup.address(videoToken: token)
        }
        #expect(link.wasCancelled)
    }

    @Test("a relay that never answers times out and the socket is dropped")
    func stalledSocketTimesOut() async {
        let link = ScriptedLink([.stall])
        let next = ScriptedLink([.message(.peerAddress(address))])
        let lookup = lookup(LinkSupply([link, next]))
        await #expect(throws: RelaySignallingError.timedOut) {
            try await lookup.address(videoToken: token, deadline: 0.01)
        }
        #expect(link.wasCancelled)
        let recovered = try? await lookup.address(videoToken: token)
        #expect(recovered == address)
        #expect(await lookup.socketsOpened == 2)
    }

    @Test("closing releases the socket")
    func closeCancels() async throws {
        let link = ScriptedLink([.message(.peerAddress(address))])
        let lookup = lookup(LinkSupply([link]))
        _ = try await lookup.address(videoToken: token)
        await lookup.close()
        #expect(link.wasCancelled)
    }
}
