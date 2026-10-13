import Foundation
import Testing

@testable import RemoteCore

/// Deliberately not a `VideoDatagramSocket`: the same type at both ends would hide a mistake in it on both sides.
private final class LoopbackSocket: @unchecked Sendable {
    enum Failure: Error {
        case unavailable(Int32)
    }

    let fd: Int32
    let port: UInt16

    init() throws {
        let descriptor = socket(AF_INET6, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw Failure.unavailable(errno) }

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = 0
        address.sin6_addr = in6addr_loopback

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Failure.unavailable(code)
        }

        var actual = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        port = UInt16(bigEndian: actual.sin6_port)

        // A deadline rather than a blocking read: a hang is worse than a failure.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        fd = descriptor
    }

    func receive() -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 2048)
        let read = recv(fd, &buffer, buffer.count, 0)
        guard read > 0 else { return [] }
        return Array(buffer[0..<read])
    }

    func send(_ bytes: [UInt8], to destination: UInt16) {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = destination.bigEndian
        address.sin6_addr = in6addr_loopback

        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
    }

    /// Named rather than `close`, which would shadow the global function and break later `close(fd)` calls.
    func closeSocket() {
        Darwin.close(fd)
    }
}

/// Observes the lifecycle: once `VideoDatagramSocket.cancel()` returns, its descriptor must no longer hold the port.
private func canBindLoopback(port: UInt16) -> Bool {
    let descriptor = socket(AF_INET6, SOCK_DGRAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }

    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = port.bigEndian
    address.sin6_addr = in6addr_loopback

    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
        }
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(datagram: Data, source: VideoDatagramSocket.Source)] = []

    func add(_ datagram: Data, _ source: VideoDatagramSocket.Source) {
        lock.withLock { items.append((datagram, source)) }
    }

    var count: Int { lock.withLock { items.count } }

    var firstFromPeer: (datagram: Data, source: VideoDatagramSocket.Source)? {
        lock.withLock {
            items.first { if case .peer = $0.source { return true } else { return false } }
        }
    }
}

@Suite("The socket that carries video, and the path it picks")
struct VideoDatagramSocketTests {
    private static let token = Data(repeating: 0xab, count: VideoDatagram.tokenSize)

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makeSocket(
        relayingTo relay: LoopbackSocket
    ) throws -> (VideoDatagramSocket, Collected) {
        let socket = try VideoDatagramSocket(
            host: "::1",
            port: relay.port,
            token: Self.token,
            label: "pl.dmq.peering.test.video"
        )
        let collected = Collected()
        socket.onDatagram = { datagram, source in collected.add(datagram, source) }
        return (socket, collected)
    }

    @Test("cancelling releases the local port before it returns")
    func cancelIsSynchronous() throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        let (socket, _) = try makeSocket(relayingTo: relay)
        let port = socket.localPort

        #expect(!canBindLoopback(port: port), "the live socket owns its port")
        socket.cancel()
        #expect(canBindLoopback(port: port), "cancel returns only after the descriptor is closed")
    }

    @Test("releasing an uncancelled socket still releases its local port")
    func deinitClosesDescriptor() throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        var socket: VideoDatagramSocket? = try makeSocket(relayingTo: relay).0
        let port = try #require(socket?.localPort)

        #expect(!canBindLoopback(port: port), "the live socket owns its port")
        socket = nil
        #expect(canBindLoopback(port: port), "deinitialization closes an owned descriptor")
    }

    @Test("cancelling a started socket releases its port once the read source is cancelled")
    func startedSocketReleasesPortAfterCancel() async throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        let (socket, _) = try makeSocket(relayingTo: relay)
        let port = socket.localPort
        socket.start()
        socket.cancel()

        #expect(await waitUntil { canBindLoopback(port: port) }, "the cancel handler closes the descriptor")
    }

    @Test("a send after cancelling is dropped without touching the closed descriptor")
    func sendAfterCancelReportsNoFailure() async throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        let (socket, _) = try makeSocket(relayingTo: relay)
        let failures = Collected()
        socket.onFailure = { _ in failures.add(Data(), .relay) }
        socket.start()
        socket.cancel()

        await withCheckedContinuation { continuation in
            socket.send([Self.token + Data([1])]) { _ in continuation.resume() }
        }
        #expect(failures.count == 0)
    }

    /// The bind tells the relay where this end is, so it must go before any held frame.
    @Test("the socket binds before it sends anything else")
    func bindsFirst() async throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        let (socket, _) = try makeSocket(relayingTo: relay)
        defer { socket.cancel() }

        socket.send([Data([0xde, 0xad])]) { _ in }
        socket.start()

        let first = relay.receive()
        #expect(first == [UInt8](Self.token), "the bind goes out ahead of the held frame")

        let second = relay.receive()
        #expect(second == [0xde, 0xad], "and the frame the caller asked for follows it")
    }

    @Test("a datagram from the relay is reported as relay traffic")
    func relayTrafficIsLabelled() async throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        let (socket, collected) = try makeSocket(relayingTo: relay)
        defer { socket.cancel() }
        socket.start()
        _ = relay.receive() // the bind

        relay.send([0x11, 0x22], to: socket.localPort)

        #expect(await waitUntil { collected.count == 1 })
        #expect(collected.firstFromPeer == nil, "an address that is the relay's is not a peer")
    }

    /// Classified by not being the relay: the Mac does not know the phone's address until a datagram arrives from it.
    @Test("a datagram from anywhere else carries the address it came from")
    func strangerAddressIsReported() async throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        let (socket, collected) = try makeSocket(relayingTo: relay)
        defer { socket.cancel() }
        socket.start()
        _ = relay.receive() // the bind

        let stranger = try LoopbackSocket()
        defer { stranger.closeSocket() }
        stranger.send([0x33], to: socket.localPort)

        #expect(await waitUntil { collected.firstFromPeer != nil })

        guard case .peer(let host, let port)? = collected.firstFromPeer?.source else {
            Issue.record("expected the sender's own address")
            return
        }
        #expect(host == "::1")
        #expect(port == stranger.port, "the sender's port, not the relay's")
    }

    /// The socket must survive being told its peer from inside the callback that reported a datagram: a `queue.sync` from there aborts. This took the Mac down the first time a probe arrived.
    @Test("the peer can be set from inside the callback that reported a datagram")
    func settingThePeerFromTheReceivePathIsSafe() async throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        let socket = try VideoDatagramSocket(
            host: "::1",
            port: relay.port,
            token: Self.token,
            label: "pl.dmq.peering.test.video.reentrant"
        )
        defer { socket.cancel() }

        let peer = try LoopbackSocket()
        defer { peer.closeSocket() }

        let collected = Collected()
        socket.onDatagram = { datagram, source in
            collected.add(datagram, source)
            try? socket.setDirectPeer(host: "::1", port: peer.port)
        }
        socket.start()
        _ = relay.receive() // the bind

        let stranger = try LoopbackSocket()
        defer { stranger.closeSocket() }
        stranger.send([0x44], to: socket.localPort)

        #expect(await waitUntil { collected.firstFromPeer != nil })
        #expect(await waitUntil { socket.hasDirectPeer })
    }

    /// The prefix is the relay's addressing only, so a direct datagram must not carry it.
    @Test("a direct send leaves the relay's token off")
    func directSendStripsTheToken() async throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        let (socket, _) = try makeSocket(relayingTo: relay)
        defer { socket.cancel() }
        socket.start()
        _ = relay.receive() // the bind

        let peer = try LoopbackSocket()
        defer { peer.closeSocket() }
        try socket.setDirectPeer(host: "::1", port: peer.port)

        let sealed = Self.token + Data([0x01, 0x02, 0x03])
        socket.sendDirect([sealed]) { _ in }

        #expect(peer.receive() == [0x01, 0x02, 0x03], "everything after the token")
    }

    /// `send` (which carries video) once kept the relay's token on direct datagrams, so receivers refused every frame while the `sendDirect` probes kept the path looking open.
    @Test("a plain send goes direct without the relay's token once the path is live")
    func plainSendStripsTheTokenOnceThePathIsLive() async throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        let (socket, collected) = try makeSocket(relayingTo: relay)
        defer { socket.cancel() }
        socket.start()
        _ = relay.receive() // the bind

        let peer = try LoopbackSocket()
        defer { peer.closeSocket() }
        try socket.setDirectPeer(host: "::1", port: peer.port)

        peer.send([0x01], to: socket.localPort)
        #expect(await waitUntil { collected.firstFromPeer != nil })

        let sealed = Self.token + Data([0x01, 0x02, 0x03])
        socket.send([sealed]) { _ in }

        #expect(
            peer.receive() == [0x01, 0x02, 0x03],
            "the token addresses the relay, and this datagram did not go to the relay"
        )
    }

    @Test("the socket moves to the peer once the peer has been heard from")
    func movesToThePeerOnceItIsHeardFrom() async throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        let (socket, collected) = try makeSocket(relayingTo: relay)
        defer { socket.cancel() }
        socket.start()
        _ = relay.receive() // the bind

        let peer = try LoopbackSocket()
        defer { peer.closeSocket() }
        #expect(socket.localPort != 0, "the local port is what the peer is given to aim at")
        try socket.setDirectPeer(host: "::1", port: peer.port)

        // Both frames start with the relay's token; the socket keeps it for the relay and strips it for the peer.
        socket.send([Self.token + Data([0xa1])]) { _ in }
        #expect(
            relay.receive() == [UInt8](Self.token) + [0xa1],
            "until the peer is heard from, the relay carries it, token and all"
        )

        peer.send([0x01], to: socket.localPort)

        #expect(await waitUntil { collected.firstFromPeer != nil })

        socket.send([Self.token + Data([0xb2])]) { _ in }
        #expect(peer.receive() == [0xb2], "and now the peer carries it, without the token")
        #expect(relay.receive() == [], "and the relay does not")
    }

    @Test("a direct send before any peer is known goes nowhere rather than to the relay")
    func directSendWithoutAPeerDoesNothing() async throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        let (socket, _) = try makeSocket(relayingTo: relay)
        defer { socket.cancel() }
        socket.start()
        _ = relay.receive() // the bind

        socket.sendDirect([Self.token + Data([0x01])]) { _ in }

        // A probe with nowhere to go must not fall back to the relay, which would make the direct path look open.
        #expect(relay.receive() == [])
    }

    /// A v4 peer on a v6 socket is the ordinary case: macOS builds `AF_INET6` for any IPv4-only relay name, and `getaddrinfo` refused it alongside an `AF_INET` peer.
    @Test("a v4 peer is reachable from a socket built in v6")
    func v4PeerOnAV6Socket() throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        let (socket, _) = try makeSocket(relayingTo: relay)
        defer { socket.cancel() }

        try socket.setDirectPeer(host: "127.0.0.1", port: relay.port)

        #expect(throws: VideoDatagramError.unusablePeerAddress("not an address")) {
            try socket.setDirectPeer(host: "not an address", port: relay.port)
        }
    }
}
