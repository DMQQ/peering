import Foundation
import NIO
import os

private let forwardLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// Whether a forward is up, and if it is not, what went wrong.
///
/// Three states rather than a boolean and an error beside it, because "starting" is a real answer
/// for a screen to draw: a listener takes a moment to bind and a user who taps twice in that moment
/// must not be shown two different things.
public enum SSHForwardState: Sendable, Equatable {
    case stopped
    case starting
    /// Listening. `problem` is the last connection the *server* refused, or nil when none has been.
    ///
    /// A refusal is not a reason to take the forward down. The listener is still good and the next
    /// connection may well succeed; what the user needs is to be told that the thing they pointed
    /// at the port did not get through, which is a different sentence and belongs beside a forward
    /// that is still running.
    case running(problem: String?)
    /// The listener could not be opened at all, which in practice means the port is already taken.
    case failed(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// What the row shows when there is nothing better to say.
    public var summary: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running(let problem): return problem ?? "Running"
        case .failed(let reason): return reason
        }
    }
}

/// The local ends of a server's forwards, and the pumping between them.
///
/// **Where this runs, and why that is the whole design.** iOS gives an app no background daemon, so
/// a forward cannot outlive the process and cannot even outlive the screen being backgrounded for
/// long. It therefore lives exactly as long as the connection that carries it: the forwarder is
/// created by whoever owns the shell, asks that shell's session for every channel it opens, and is
/// stopped when the shell ends. There is no other arrangement available, and the UI says so rather
/// than leaving the user to find out when their tunnel quietly stops.
///
/// ## What it owns
///
/// One listening socket per forward, on `127.0.0.1` and nowhere else — see ``SSHPortForward`` for
/// why that is not configurable. Each accepted connection becomes a `direct-tcpip` channel through
/// the server, and the two are then pumped into each other for as long as either lasts.
///
/// ## Why the dialer is a closure
///
/// The thing that can open a channel is the SSH client, and the client is not `Sendable`: it lives
/// inside the task that owns the connection, and everything in this package is arranged so that it
/// stays there. So this type never sees it. It is handed a `@Sendable` closure that asks the
/// session for a channel and gets back a wrapped, `Sendable` one, which means the pumping below
/// runs in tasks of its own with nothing borrowed from the connection.
public actor SSHForwarder {
    /// Opens a channel through the server. Supplied by ``SSHSession/openDirectChannel(to:port:from:)``.
    public typealias Dial = @Sendable (_ host: String, _ port: Int, _ localPort: Int) async throws
        -> NIOAsyncChannel<ByteBuffer, ByteBuffer>

    private let dial: Dial
    /// Every state change, newest only.
    ///
    /// A screen has to be told about a refused connection as well as a stopped forward, and a
    /// connection is refused by the *server* long after the user pressed anything: without this the
    /// row would say Running until the sheet was closed and opened again, which is exactly the
    /// moment the user has stopped looking. Newest-only because the states are the whole value and
    /// an intermediate set nobody drew is not worth holding.
    public nonisolated let changes: AsyncStream<[UUID: SSHForwardState]>
    private nonisolated let announce: AsyncStream<[UUID: SSHForwardState]>.Continuation

    private var listeners: [UUID: Channel] = [:]
    private var states: [UUID: SSHForwardState] = [:]
    /// The connections currently being carried, so stopping a forward means stopping them too.
    ///
    /// A listener's channel closing does not close the connections it accepted, and a "Stop" that
    /// left a file transfer running would be a button that does not do what it says.
    private var connections: [UUID: [Channel]] = [:]

    public init(dial: @escaping Dial) {
        self.dial = dial
        (changes, announce) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// The state of every forward this has been asked about, including ones that are stopped.
    public var allStates: [UUID: SSHForwardState] { states }

    public func state(of id: UUID) -> SSHForwardState {
        states[id] ?? .stopped
    }

    /// One write of the states, so no caller has to remember to announce as well as set.
    private func set(_ state: SSHForwardState, for id: UUID) {
        states[id] = state
        announce.yield(states)
    }

    // MARK: - Starting and stopping

    /// Binds the local port and starts accepting on it.
    ///
    /// Throws when the port cannot be bound, which is the one failure the user can act on and the
    /// one they will actually meet: a port already in use by another app, or by another forward on
    /// another server. The message from NIO is kept rather than replaced, because `address already
    /// in use` is the sentence that tells them what to do.
    public func start(_ forward: SSHPortForward) async throws {
        guard listeners[forward.id] == nil else { return }
        set(.starting, for: forward.id)

        let dial = self.dial
        let id = forward.id
        let localPort = forward.localPort

        let bootstrap = ServerBootstrap(group: Self.group)
            // Loopback and nothing else, for the reason ``SSHPortForward`` gives at length. Spelled
            // as an address rather than as `localhost` so it cannot resolve to something else on a
            // machine with an unusual resolver.
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                do {
                    // Wrapped here, synchronously, on the accepted channel's own loop and before it
                    // is read from — which is the only moment this is legal, and the reason the
                    // hand-off below is a `Task` rather than an `await` in the initialiser.
                    let local = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                    Task { [weak self] in
                        guard let self else {
                            // The forwarder is gone, so this connection has nowhere to go. Finished
                            // by hand rather than merely closed, because a `NIOAsyncChannel` that is
                            // deallocated without its scoped body having run is a fatal error in
                            // NIO rather than a leak — which is how this line was found.
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
            // The port named in the sentence as well as the operating system's reason for it,
            // because the state is what the row draws and the row is the only place a user reads
            // this. "Address already in use" on its own says nothing about which port, and the
            // number is the one thing they can act on.
            let reason = SSHForwardError.cannotListen(
                port: forward.localPort,
                reason: Self.describe(error)
            )
            set(.failed(reason.message), for: forward.id)
            throw reason
        }
    }

    /// Stops listening and ends every connection going through it.
    public func stop(_ id: UUID) async {
        set(.stopped, for: id)
        listeners.removeValue(forKey: id)?.close(promise: nil)
        for connection in connections.removeValue(forKey: id) ?? [] {
            connection.close(promise: nil)
        }
    }

    /// Ends everything. What a shell closing does.
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

    /// Records an accepted connection so that stopping the forward can end it.
    ///
    /// The `guard` is not defensive: a connection accepted in the moment a forward is stopped
    /// arrives here *after* the stop, and without this it would be a tunnel still carrying traffic
    /// under a row that says Stopped. Both halves are actor-isolated, so the two orders are the
    /// only two there are, and both come out with the connection closed.
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

    /// One forwarded connection, from the local socket to the server's channel and back.
    ///
    /// A task per connection rather than a channel handler, because both ends are already wrapped
    /// as async channels and doing it this way means the backpressure is NIO's own: when one side
    /// stops being writable the `for try await` below stops pulling, which stops that channel being
    /// read, which is the whole mechanism. A pair of hand-written handlers would have to reproduce
    /// it, and the failure of getting it wrong is the one that does not show up until a phone
    /// streaming a large file through a tunnel is killed for memory.
    ///
    /// `forwarder` is weak and only used to record a refused connection on the forward's own row.
    /// The task does not keep the forwarder alive; the forwarder does not keep the tasks alive
    /// either, because closing the listener ends the connections it accepted.
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
            // The local connection was accepted and has nowhere to go, so it is dropped: an app
            // that connected to the port sees the connection close, which is what it would see
            // from any tunnel whose far end refused, rather than hanging until it times out.
            //
            // Closed through `executeThenClose` with an empty body rather than by closing the
            // channel underneath it, and that is not a stylistic choice: an `NIOAsyncChannel` that
            // is deallocated without its scoped body having run is a **fatal error** in NIO, so the
            // shorter spelling crashes the app on the path that runs whenever a server refuses.
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
                        // Whichever side finishes first ends the other. A forward has no half-open
                        // state worth preserving: one end closing is the connection being over.
                        defer { group.cancelAll() }
                        try await group.next()
                    }
                }
            }
        } catch {
            // Ordinary. A connection that ended because the far end closed, or because the user
            // shut the forward down, lands here, and logging it at error level would make a working
            // tunnel look like a broken one in the console.
            forwardLog.debug("forwarded connection ended: \(String(describing: error), privacy: .public)")
        }
    }

    /// Records that a connection was refused, leaving the listener running.
    private func note(problem: String, for id: UUID) {
        guard case .running = states[id] else { return }
        set(.running(problem: problem), for: id)
    }

    /// The sentence a refusal is reported with.
    ///
    /// Public because the app has a second place that has to say the same thing: the shell's own
    /// error line, which would otherwise print a Swift description of an error it has no business
    /// knowing the shape of. One wording, so a refusal cannot read one way in the ports sheet and
    /// another on the terminal.
    ///
    /// `SSHSessionError` is read for the one case worth rewording: `notConnected` arrives when the
    /// shell has ended, and "the connection ended" printed under a *forward* reads as though the
    /// tunnel broke rather than as though the shell it lived on was closed.
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

    /// The threads the listeners accept on.
    ///
    /// NIO's shared group rather than one per forwarder, and the reason is lifetime rather than
    /// thrift: a group owned by this object would have to be shut down at exactly the moment its
    /// last listener closes, and a shutdown raced by one accepted connection is a crash. The
    /// process has one of these for its whole life, which is what this needs too.
    private static let group = MultiThreadedEventLoopGroup.singleton
}

/// Why a forward could not be opened at all.
public enum SSHForwardError: Error, Sendable, Equatable {
    /// The local port could not be listened on, nearly always because something already is.
    case cannotListen(port: Int, reason: String)

    public var message: String {
        switch self {
        case .cannotListen(let port, let reason):
            return "Could not listen on \(port): \(reason)"
        }
    }
}
