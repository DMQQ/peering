import Foundation
import NIO
import Testing

@testable import SSHCore

/// The forwarder, driven with a dialer that goes somewhere real.
///
/// No SSH in here, and that is the point rather than a limitation. What the forwarder does is bind
/// a loopback port, accept on it, ask somebody for a channel, and pump bytes between the two until
/// one end closes. The *somebody* is the only part that needs a server, and it is a closure — so
/// these tests hand it a plain TCP connection to an echo server and measure everything on either
/// side of it. A real `sshd` is not installed on the machine these run on and could not be started
/// without an administrator, which is the other reason this shape was worth having.
///
/// What is *not* covered here, and is worth saying out loud: that Citadel's `direct-tcpip` channel
/// open is what a given server accepts. That needs a server, and the code path for it is one call
/// in ``SSHSession`` rather than anything in this file.
@Suite("Port forwarding")
struct SSHForwarderTests {
    /// A port nothing is listening on.
    ///
    /// Bound and released rather than picked at random, so the number is one the kernel has just
    /// agreed is free. There is a race in principle between the release and the forward binding it,
    /// and it is the same race every test that wants a fixed port on a shared machine has.
    private func freePort() async throws -> Int {
        let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = probe.localAddress?.port ?? 0
        try await probe.close().get()
        return port
    }

    /// A listener that sends back whatever it is sent.
    ///
    /// Stands in for the service at the far end of a tunnel, which is the only thing a forward
    /// promises to deliver to.
    private func echoServer() async throws -> (channel: Channel, port: Int) {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return (channel, channel.localAddress?.port ?? 0)
    }

    /// A dialer that connects to the echo server directly, standing in for the SSH channel.
    private func echoDialer() -> SSHForwarder.Dial {
        { host, port, _ in
            try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connect(host: host, port: port)
                .flatMapThrowing { channel in
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
                .get()
        }
    }

    /// Waits for an actor's state to become something, because the states are pushed rather than
    /// returned and the push happens on another task.
    ///
    /// Bounded, because a test that waits forever on a bug takes the whole run down with it and
    /// reports nothing about which one it was.
    private func wait(
        upTo seconds: Double = 3,
        for condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test("a connection to the forwarded port comes out at the far end, and the answer comes back")
    func carriesBytesBothWays() async throws {
        let echo = try await echoServer()
        defer { echo.channel.close(promise: nil) }

        let port = try await freePort()
        let forwarder = SSHForwarder(dial: echoDialer())
        let forward = SSHPortForward(localPort: port, remoteHost: "127.0.0.1", remotePort: echo.port)

        try await forwarder.start(forward)
        #expect(await forwarder.state(of: forward.id) == .running(problem: nil))

        let client = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: port)
            .flatMapThrowing { channel in
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }
            .get()

        try await client.executeThenClose { inbound, outbound in
            try await outbound.write(ByteBuffer(string: "through the tunnel"))

            var answers = inbound.makeAsyncIterator()
            let answer = try await answers.next()
            #expect(answer.map { String(buffer: $0) } == "through the tunnel")
        }

        await forwarder.stopAll()
    }

    @Test("a forward binds its own port, and stopping it gives the port back")
    func stopReleasesThePort() async throws {
        let port = try await freePort()
        let forwarder = SSHForwarder(dial: echoDialer())
        let forward = SSHPortForward(localPort: port, remoteHost: "127.0.0.1", remotePort: 9)

        try await forwarder.start(forward)
        await forwarder.stop(forward.id)
        #expect(await forwarder.state(of: forward.id) == .stopped)

        // The port is free again, which is the whole of what "stopped" has to mean: a forward the
        // user turned off that still holds its port is one that cannot be turned back on.
        let again = SSHForwarder(dial: echoDialer())
        try await again.start(forward)
        #expect(await again.state(of: forward.id) == .running(problem: nil))
        await again.stopAll()
    }

    @Test("a port that is already taken is a failure the row can say out loud")
    func aTakenPortFails() async throws {
        let port = try await freePort()
        let first = SSHForwarder(dial: echoDialer())
        let forward = SSHPortForward(localPort: port, remoteHost: "127.0.0.1", remotePort: 9)

        try await first.start(forward)
        defer { Task { await first.stopAll() } }

        // A second forward on the same port, which is what two servers configured with the same
        // number look like from here, or one server opened twice.
        let second = SSHForwarder(dial: echoDialer())
        await #expect(throws: SSHForwardError.self) {
            try await second.start(forward)
        }

        // The state carries the same sentence the throw did, because that is where the user reads
        // it — the throw is for the caller, and the caller has nowhere to put it.
        guard case .failed(let reason) = await second.state(of: forward.id) else {
            Issue.record("expected a failed state, got \(await second.state(of: forward.id))")
            return
        }
        #expect(reason.contains("\(port)"))
        #expect(reason.contains("Could not listen"))
        #expect(SSHForwardError.cannotListen(port: port, reason: "in use").message.contains("\(port)"))
    }

    @Test("a connection the far end refuses is recorded, and the listener stays up")
    func aRefusedConnectionIsRecorded() async throws {
        let port = try await freePort()
        let forwarder = SSHForwarder(dial: { _, _, _ in
            throw SSHSessionError.notConnected
        })
        let forward = SSHPortForward(localPort: port, remoteHost: "127.0.0.1", remotePort: 9)

        try await forwarder.start(forward)

        let client = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: port)
            .flatMapThrowing { channel in
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }
            .get()

        // The local connection is dropped rather than left hanging. A tunnel whose far end said no
        // has to look to the app that connected like a refused connection, not like a slow one.
        try await client.executeThenClose { inbound, _ in
            var answers = inbound.makeAsyncIterator()
            let answer = try await answers.next()
            #expect(answer == nil)
        }

        let recorded = await wait {
            if case .running(let problem) = await forwarder.state(of: forward.id) { return problem != nil }
            return false
        }
        #expect(recorded)

        // And the listener is still there: one refused connection is one refused connection, not a
        // reason to take the tunnel down under a user who may well try again in a second.
        #expect(await forwarder.state(of: forward.id).isRunning)
        await forwarder.stopAll()
    }

    @Test("stopping a forward ends the connections going through it")
    func stopEndsLiveConnections() async throws {
        let echo = try await echoServer()
        defer { echo.channel.close(promise: nil) }

        let port = try await freePort()
        let forwarder = SSHForwarder(dial: echoDialer())
        let forward = SSHPortForward(localPort: port, remoteHost: "127.0.0.1", remotePort: echo.port)
        try await forwarder.start(forward)

        let client = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: port)
            .flatMapThrowing { channel in
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }
            .get()

        try await client.executeThenClose { inbound, outbound in
            try await outbound.write(ByteBuffer(string: "open"))
            var answers = inbound.makeAsyncIterator()
            _ = try await answers.next()

            // Stopped while it is carrying something. A "Stop" that left the connection running
            // would be a button that does not do what it says.
            await forwarder.stop(forward.id)

            let answer = try await answers.next()
            #expect(answer == nil)
        }
    }

    @Test("the states are announced as well as held, for a screen that is already open")
    func statesAreAnnounced() async throws {
        let port = try await freePort()
        let forwarder = SSHForwarder(dial: echoDialer())
        let forward = SSHPortForward(localPort: port, remoteHost: "127.0.0.1", remotePort: 9)

        // The stream has to exist before the change, or it would be a stream that only ever reports
        // what has not happened yet. Watching for the *last* state and not the first, because a
        // start is two writes and the first of them is `starting` — a screen that returned on that
        // one would draw a forward that had not bound anything.
        let seen = Task { () -> SSHForwardState? in
            for await states in forwarder.changes {
                if let state = states[forward.id], state.isRunning { return state }
            }
            return nil
        }

        try await forwarder.start(forward)
        #expect(await seen.value == .running(problem: nil))
        await forwarder.stopAll()
    }
}

/// Sends back what it is sent. The far end of a tunnel, in a handful of lines.
private final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(NIOAny(unwrapInboundIn(data)), promise: nil)
    }
}
