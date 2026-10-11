import Foundation
import NIO
import os

private let forwardLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// Three states rather than a boolean and an error, because "starting" is a real answer for a screen to draw.
public enum SSHForwardState: Sendable, Equatable {
    case stopped
    case starting
    /// Listening. `problem` is the last connection the server refused; a refusal does not take the forward down, the next connection may succeed.
    case running(problem: String?)
    case failed(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running(let problem): return problem ?? "Running"
        case .failed(let reason): return reason
        }
    }
}

/// The local ends of a server's forwards, and the pumping between them. iOS has no background daemon, so a forward lives exactly as long as the shell that carries it: it is created by the shell's owner and stopped when the shell ends.
/// One listening socket per forward, on `127.0.0.1` only (see ``SSHPortForward``); each accepted connection becomes a `direct-tcpip` channel through the server.
/// The dialer is a `@Sendable` closure because the SSH client is not `Sendable` and stays in the task that owns the connection; the pumping runs in tasks of its own with nothing borrowed from it.
public actor SSHForwarder {
    public typealias Dial = @Sendable (_ host: String, _ port: Int, _ localPort: Int) async throws
        -> NIOAsyncChannel<ByteBuffer, ByteBuffer>

    private let dial: Dial
    /// Every state change, newest only. A refusal arrives from the server long after the user pressed anything, so without this the row would say Running until the sheet was reopened.
    public nonisolated let changes: AsyncStream<[UUID: SSHForwardState]>
    private nonisolated let announce: AsyncStream<[UUID: SSHForwardState]>.Continuation

    private var listeners: [UUID: Channel] = [:]
    private var states: [UUID: SSHForwardState] = [:]
    /// The connections currently being carried; a listener closing does not close what it accepted, so stopping must end them too.
    private var connections: [UUID: [Channel]] = [:]

    public init(dial: @escaping Dial) {
        self.dial = dial
        (changes, announce) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public var allStates: [UUID: SSHForwardState] { states }

    public func state(of id: UUID) -> SSHForwardState {
        states[id] ?? .stopped
    }

    private func set(_ state: SSHForwardState, for id: UUID) {
        states[id] = state
        announce.yield(states)
    }

    // MARK: - Starting and stopping

    /// Throws when the port cannot be bound (in use by another app or forward). NIO's message is kept because `address already in use` tells the user what to do.
    public func start(_ forward: SSHPortForward) async throws {
        guard listeners[forward.id] == nil else { return }
        set(.starting, for: forward.id)

        let dial = self.dial
        let id = forward.id
        let localPort = forward.localPort

        let bootstrap = ServerBootstrap(group: Self.group)
            // Loopback only, spelled as an address so it cannot resolve to something else.
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                do {
                    // Wrapped synchronously on the accepted channel's own loop before it is read from, the only legal moment; hence the hand-off below is a `Task`.
                    let local = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                    Task { [weak self] in
                        guard let self else {
                            // Finished by hand rather than merely closed: a `NIOAsyncChannel` deallocated without its scoped body having run is a fatal error in NIO.
                            try? await local.executeThenClose { _, _ in }
                            return
                        }
                        await self.track(channel, for: id)
                        await Self.pump(local, id: id, dial: dial, forward: forward, forwarder: self)
                    }
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        do {
            let listener = try await bootstrap.bind(host: "127.0.0.1", port: forward.localPort).get()
            listeners[forward.id] = listener
            set(.running(problem: nil), for: forward.id)
            forwardLog.info("forward on \(localPort, privacy: .public) is listening")
        } catch {
            // The port is named as well as the OS reason: "Address already in use" alone does not say which, and the row is the only place the user reads this.
            let reason = SSHForwardError.cannotListen(
                port: forward.localPort,
                reason: Self.describe(error)
            )
            set(.failed(reason.message), for: forward.id)
            throw reason
        }
    }

    public func stop(_ id: UUID) async {
        set(.stopped, for: id)
        listeners.removeValue(forKey: id)?.close(promise: nil)
        for connection in connections.removeValue(forKey: id) ?? [] {
            connection.close(promise: nil)
        }
    }

    public func stopAll() async {
        for (_, listener) in listeners {
            listener.close(promise: nil)
        }
        for (_, carried) in connections {
            for connection in carried { connection.close(promise: nil) }
        }
        listeners.removeAll()
        connections.removeAll()
        for id in states.keys { states[id] = .stopped }
        announce.yield(states)
    }

    /// The `guard` is not defensive: a connection accepted just as the forward is stopped arrives after the stop and would otherwise keep carrying traffic under a Stopped row.
    private func track(_ channel: Channel, for id: UUID) {
        guard listeners[id] != nil else {
            channel.close(promise: nil)
            return
        }
        connections[id, default: []].append(channel)
        channel.closeFuture.whenComplete { [weak self] _ in
            Task { await self?.untrack(channel, for: id) }
        }
    }

    private func untrack(_ channel: Channel, for id: UUID) {
        connections[id]?.removeAll { $0 === channel }
        if connections[id]?.isEmpty == true { connections.removeValue(forKey: id) }
    }

    // MARK: - The pumping

    /// A task per connection rather than a channel handler, so backpressure is NIO's own: when one side stops being writable the `for try await` stops pulling. Hand-written handlers would have to reproduce it, and getting it wrong only shows when a large transfer is killed for memory.
    /// `forwarder` is weak and only used to record a refused connection on the forward's own row.
    private static func pump(
        _ local: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        id: UUID,
        dial: Dial,
        forward: SSHPortForward,
        forwarder: SSHForwarder?
    ) async {
        let remote: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        do {
            remote = try await dial(forward.remoteHost, forward.remotePort, forward.localPort)
        } catch {
            // Closed through `executeThenClose` with an empty body, not by closing the channel underneath: a `NIOAsyncChannel` deallocated without its scoped body having run is a fatal error in NIO, and this path runs whenever a server refuses.
            try? await local.executeThenClose { _, _ in }
            await forwarder?.note(problem: Self.describe(error), for: id)
            return
        }

        do {
            try await local.executeThenClose { inboundLocal, outboundLocal in
                try await remote.executeThenClose { inboundRemote, outboundRemote in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await buffer in inboundLocal {
                                try await outboundRemote.write(buffer)
                            }
                        }
                        group.addTask {
                            for try await buffer in inboundRemote {
                                try await outboundLocal.write(buffer)
                            }
                        }
                        // Whichever side finishes first ends the other; there is no useful half-open state.
                        defer { group.cancelAll() }
                        try await group.next()
                    }
                }
            }
        } catch {
            // Ordinary: a far-end close or a forward being shut down; logging it at error level would make a working tunnel look broken.
            forwardLog.debug("forwarded connection ended: \(String(describing: error), privacy: .public)")
        }
    }

    private func note(problem: String, for id: UUID) {
        guard case .running = states[id] else { return }
        set(.running(problem: problem), for: id)
    }

    /// Public because the shell's own error line must say the same thing. `notConnected` is reworded, since "the connection ended" under a forward reads as the tunnel breaking rather than its shell closing.
    public static func describe(_ error: any Error) -> String {
        if let error = error as? SSHSessionError {
            switch error {
            case .notConnected:
                return "The shell this forward runs on has ended."
            case .forward(let reason):
                return describeForward(reason)
            case .transport(let reason), .browse(let reason):
                return reason
            case .hostKeyRejected:
                return "This server's key was not accepted."
            case .hostKeyChanged:
                return "This server's key has changed."
            }
        }
        return String(describing: error)
    }

    private static func describeForward(_ error: any Error) -> String {
        if let error = error as? SSHForwardError { return error.message }
        return String(describing: error)
    }

    /// NIO's shared group rather than one per forwarder: shutting down an owned group races accepted connections and crashes.
    private static let group = MultiThreadedEventLoopGroup.singleton
}

public enum SSHForwardError: Error, Sendable, Equatable {
    case cannotListen(port: Int, reason: String)

    public var message: String {
        switch self {
        case .cannotListen(let port, let reason):
            return "Could not listen on \(port): \(reason)"
        }
    }
}
