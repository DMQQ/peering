import Foundation
import Testing

@testable import RemoteCore

/// A bare UDP socket on loopback, for the other end of a test.
///
/// Deliberately *not* a `VideoDatagramSocket`. What these tests are about is what the socket under
/// test does with bytes from a particular address, and putting the same type at both ends would make
/// a mistake in it invisible on both sides at once.
private final class LoopbackSocket: @unchecked Sendable {
    enum Failure: Error {
        case unavailable(Int32)
    }

    let fd: Int32
    let port: UInt16

    init() throws {
        // A local rather than `fd` throughout: a closure that captured `self` here would be reading
        // a property before the other one had been initialised, which Swift refuses — and rightly,
        // since the whole point of the object is that the two agree.
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

        // A deadline rather than a blocking read with none: every wait here is for something that
        // either happens in milliseconds on loopback or never happens at all, and a test that hangs
        // on the second kind is worse than one that fails.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        fd = descriptor
    }

    /// One datagram, or nothing if none arrived inside the timeout.
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

    /// Named rather than `close`, which is a global function this would otherwise shadow inside the
    /// type — the kind of shadowing that makes every later `close(fd)` in the file a compile error
    /// pointing somewhere unhelpful.
    func closeSocket() {
        Darwin.close(fd)
    }
}

/// Whether a fresh UDP socket can take a specific loopback port right now.
///
/// Used as the public lifecycle observation: once `VideoDatagramSocket.cancel()` returns, the
/// descriptor it owned must no longer hold its local port.
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

/// What a socket under test was handed, gathered off its own queue.
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

    /// Waits for something done on another queue, and gives up rather than hanging.
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

    /// The bind is what tells the relay where this end is, and nothing is forwarded to an address
    /// the relay has not been told about — so it has to go first, before any held frame.
    @Test("the socket binds before it sends anything else")
    func bindsFirst() async throws {
        let relay = try LoopbackSocket()
        defer { relay.closeSocket() }
        let (socket, _) = try makeSocket(relayingTo: relay)
        defer { socket.cancel() }

        // Asked for before the socket is started, so it can only have been held.
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

    /// The classification is by *not being the relay* rather than by matching a known peer, because
    /// the Mac does not know the phone's address until a datagram arrives from it — a rule that
    /// required knowing it first could never learn it.
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

    /// **The receive path is one of the things that establishes where to send**, so the socket has
    /// to survive being told its peer from inside the callback that reported a datagram.
    ///
    /// This is what `VideoDatagramLane.accept` does, and it is the shape that took the Mac down the
    /// first time a probe ever arrived: the callback runs on the socket's own queue via the read
    /// source, and a `queue.sync` from there is not a wait but an abort. It could not be caught
    /// before because the direct path was inert, so nothing ever called into the socket this way.
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
            // The lane's line, in the lane's position: on this queue, inside this callback.
            try? socket.setDirectPeer(host: "::1", port: peer.port)
        }
        socket.start()
        _ = relay.receive() // the bind

        let stranger = try LoopbackSocket()
        defer { stranger.closeSocket() }
        stranger.send([0x44], to: socket.localPort)

        #expect(await waitUntil { collected.firstFromPeer != nil })
        // And it took: the socket has somewhere to send now, which is the whole reason the call is
        // made from here rather than from a timer.
        #expect(await waitUntil { socket.hasDirectPeer })
    }

    /// The prefix is the relay's addressing and nothing else, so a datagram going straight to the
    /// one endpoint that could want it must not carry it.
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

    /// **The case the framing got wrong, and the one that cost every direct session its picture.**
    ///
    /// `sendDirect` stripped the relay's token and `send` did not, and `send` is what carries
    /// video. So the moment a punch opened, every frame went to the peer with sixteen bytes of
    /// relay addressing still in front of it, which the receiver read as its counter and refused.
    /// The probes came from `sendDirect` and kept working, so the path looked open from both ends
    /// while no picture ever completed, and the client said "some of the Mac's video datagrams
    /// could not be read" — which reads like a lossy network and was a framing mistake.
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

        // The peer speaks once, which is the whole of what makes the direct path live.
        peer.send([0x01], to: socket.localPort)
        #expect(await waitUntil { collected.firstFromPeer != nil })

        let sealed = Self.token + Data([0x01, 0x02, 0x03])
        socket.send([sealed]) { _ in }

        #expect(
            peer.receive() == [0x01, 0x02, 0x03],
            "the token addresses the relay, and this datagram did not go to the relay"
        )
    }

    /// The whole mechanism in one test: the socket is on the relay, the peer speaks, and every send
    /// after that goes to the peer instead — with nothing negotiated and nothing acknowledged.
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

        // Both frames carry the relay's token, because that is the shape ``VideoDatagramSealer``
        // produces and the only shape this socket is ever handed. What changes with the
        // destination is whether the socket keeps it: the relay needs it to know which session a
        // datagram belongs to, and the peer has no relay to ask.
        //
        // Nothing has arrived from the peer, so the peer is only a place the socket *could* send.
        socket.send([Self.token + Data([0xa1])]) { _ in }
        #expect(
            relay.receive() == [UInt8](Self.token) + [0xa1],
            "until the peer is heard from, the relay carries it, token and all"
        )

        // The peer speaks. That is the whole of what "the path is open" means.
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

        // A probe with nowhere to go must not fall back to the relay: the relay would forward it to
        // the peer anyway, which would make it look like the direct path worked when it did not.
        #expect(relay.receive() == [])
    }
}
