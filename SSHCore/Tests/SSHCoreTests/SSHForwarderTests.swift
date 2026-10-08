import Foundation
import NIO
import Testing

@testable import SSHCore

/// No SSH in here: the dialer is a closure, so these tests hand it a plain TCP connection to an echo server. Not covered: that a given server accepts Citadel's `direct-tcpip` channel open, which needs one.
@Suite("Port forwarding")
struct SSHForwarderTests {
    /// A port nothing is listening on, bound and released; there is a small race before the forward binds it, as with any fixed-port test.
    private func freePort() async throws -> Int {
        let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = probe.localAddress?.port ?? 0
        try await probe.close().get()
        return port
    }

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

    /// Bounded, so a test waiting on a bug does not take the run down.
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

        // A forward that was turned off but still holds its port cannot be turned back on.
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

        let second = SSHForwarder(dial: echoDialer())
        await #expect(throws: SSHForwardError.self) {
            try await second.start(forward)
        }

        // The state carries the same sentence as the throw: the state is where the user reads it.
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

        // The local connection is dropped, so the app sees a refusal rather than a slow connection.
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

        // Watching for the last state, not the first: a start is two writes and the first is `starting`.
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

private final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(NIOAny(unwrapInboundIn(data)), promise: nil)
    }
}
