import Citadel
import Crypto
import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH
import RemoteCore
import os

private let sessionLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// The algorithm is carried beside the fingerprint because it explains a change: `ssh-ed25519` then `rsa-sha2-256` changes the fingerprint without an attack, and a hash alone would look like one.
public struct SSHHostKeyPrompt: Sendable, Equatable {
    public let endpoint: SSHEndpoint
    public let algorithm: String
    public let fingerprint: String

    public init(endpoint: SSHEndpoint, algorithm: String, fingerprint: String) {
        self.endpoint = endpoint
        self.algorithm = algorithm
        self.fingerprint = fingerprint
    }
}

public enum SSHSessionError: Error, Sendable {
    case hostKeyRejected(SSHHostKeyPrompt)
    /// A host already known offered a different key. Deliberately not reachable by agreeing to something: a one-tap accept would turn the check into a formality, since the moment it matters is when the user is hurried.
    case hostKeyChanged(known: KnownHost, presented: SSHHostKeyPrompt)
    case transport(String)
    case notConnected
    /// Not a variant of ``transport``: a missing folder, a non-text file or a server with no SFTP are ordinary answers, not a broken connection.
    case browse(String)
    /// Separate from ``transport`` for the same reason: a refused channel to `db.internal:5432` says nothing about the shell, which stays usable, and the user needs to know which tunnel failed.
    case forward(any Error)
}

public enum SSHSessionEvent: Sendable {
    case connected
    /// Bytes from the server. stdout and stderr arrive as one stream: on a PTY they are the same descriptor.
    case output(Data)
    case failed(SSHSessionError)
    case closed
}

/// A struct rather than a closure because the three outcomes differ: a known key succeeds silently, a changed key fails outright, and a new one suspends the handshake on a human. `validateHostKey` runs on NIO's event loop and must answer through a promise, so the asking happens in a `Task` and the server waits mid-handshake, before anything assumes a trusted peer.
struct SSHHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let endpoint: SSHEndpoint
    let store: SSHKnownHosts
    let ask: @Sendable (SSHHostKeyPrompt) async -> Bool
    let record: @Sendable (SSHHostKeyPrompt, Data) -> Void

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // The blob is what OpenSSH hashes and `write(to:)` is the only byte-exact way to get it; deriving it from `String(openSSHPublicKey:)` is one refactor from a fingerprint that no longer matches `ssh-keygen -lf`.
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        hostKey.write(to: &buffer)
        let blob = Data(buffer: buffer)

        // `keyPrefix` is internal to NIOSSH, so the algorithm is read back off the OpenSSH rendering.
        let rendered = String(openSSHPublicKey: hostKey)
        let algorithm = rendered.split(separator: " ").first.map(String.init) ?? "unknown"

        let presented = SSHHostKeyPrompt(
            endpoint: endpoint,
            algorithm: algorithm,
            fingerprint: SSHFingerprint.string(of: blob)
        )

        switch store.decision(for: endpoint, publicKey: blob) {
        case .match:
            validationCompletePromise.succeed(())

        case .changed(let known):
            sessionLog.error("host key changed for \(self.endpoint.key, privacy: .public)")
            validationCompletePromise.fail(
                SSHSessionError.hostKeyChanged(known: known, presented: presented)
            )

        case .unknown:
            let ask = self.ask
            let record = self.record
            Task {
                let accepted = await ask(presented)
                if accepted {
                    record(presented, blob)
                    validationCompletePromise.succeed(())
                } else {
                    validationCompletePromise.fail(SSHSessionError.hostKeyRejected(presented))
                }
            }
        }
    }
}

/// Boxed to move into tasks. `TTYOutput` and `TTYStdinWriter` are thin handles over one NIO `Channel`, safe from any thread, but Citadel does not declare them `Sendable` (public conformance is not inferred across modules), so it is asserted here once.
struct BoxedShell: @unchecked Sendable {
    let inbound: TTYOutput
    let outbound: TTYStdinWriter
}

/// A lock rather than actor state: `TTYStdinWriter` is not `Sendable`, so storing it in an actor is itself a "sending" error.
private final class ShellHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var boxed: BoxedShell?
    private var columns: Int
    private var rows: Int

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    /// Every access goes through one of these four synchronous helpers: `NSLock` may not be held across a suspension point, and an `await` inside the critical section would let another command in between the read and the write.
    private func swap(_ shell: BoxedShell?) -> BoxedShell? {
        lock.lock()
        defer { lock.unlock() }
        let previous = boxed
        boxed = shell
        return previous
    }

    private var current: BoxedShell? {
        lock.lock()
        defer { lock.unlock() }
        return boxed
    }

    private func record(columns: Int, rows: Int) -> (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        self.columns = columns
        self.rows = rows
        return (columns, rows)
    }

    private func size() -> (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (columns, rows)
    }

    func attach(_ shell: BoxedShell) async {
        _ = swap(shell)
        // A resize made while the connection was still opening is applied once there is a shell.
        let (cols, rowCount) = size()
        try? await shell.outbound.changeSize(cols: cols, rows: rowCount, pixelWidth: 0, pixelHeight: 0)
    }

    func detach() {
        _ = swap(nil)
    }

    /// Read by browse requests: a request yielded with no loop running would hold a continuation nothing resumes. It covers a session still connecting and one whose connection failed; the rest is caught by the yield itself (see ``SSHSession/browse(_:at:)``).
    var isAttached: Bool {
        current != nil
    }

    func send(_ data: Data) async throws {
        guard let shell = current else { throw SSHSessionError.notConnected }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await shell.outbound.write(buffer)
    }

    func resize(columns: Int, rows: Int) async throws {
        let (cols, rowCount) = record(columns: columns, rows: rows)
        guard let shell = current else { return }
        try await shell.outbound.changeSize(cols: cols, rows: rowCount, pixelWidth: 0, pixelHeight: 0)
    }
}

/// A continuation, as for ``SSHBrowseRequest``. This hands back a live channel, which is safe because NIO's `Channel` is `Sendable` (every method hops onto its own event loop); the client that made it is not and stays in the task.
struct SSHForwardRequest: Sendable {
    let host: String
    let port: Int
    let localPort: Int
    let continuation: CheckedContinuation<NIOAsyncChannel<ByteBuffer, ByteBuffer>, any Error>
}

private enum SSHCommand: Sendable {
    case write(Data)
    case resize(columns: Int, rows: Int)
    case browse(SSHBrowseRequest)
    case forward(SSHForwardRequest)
    case close
}

/// The two-window problem of ``ShellHandle/isAttached`` with different windows: a forward is legitimate from when the transport is up (before the shell attaches, while keyboard-interactive may still be authenticating) until the command loop ends. The shell's flag would refuse the first and allow the second. A lock because the reader is a synchronous `guard`.
final class SSHConnectionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isUp = false

    var value: Bool {
        get { lock.withLock { isUp } }
        set { lock.withLock { isUp = newValue } }
    }
}

/// Everything the connection owns is created inside the task that runs it: `SSHClient` is not `Sendable`, so the answer is confinement rather than an `@unchecked` box. Hence ``connect()`` cannot return the connection and failures are reported on ``events``.
public final class SSHSession: Sendable {
    public let events: AsyncStream<SSHSessionEvent>

    private let emit: AsyncStream<SSHSessionEvent>.Continuation
    private let commands: AsyncStream<SSHCommand>
    private let issue: AsyncStream<SSHCommand>.Continuation
    private let shell: ShellHandle
    private let isUp = SSHConnectionFlag()

    private let endpoint: SSHEndpoint
    private let username: String
    private let credential: SSHCredential
    private let knownHosts: SSHKnownHosts
    private let ask: @Sendable (SSHHostKeyPrompt) async -> Bool

    public init(
        host: SSHHost,
        credential: SSHCredential,
        knownHosts: SSHKnownHosts = SSHKnownHosts(),
        columns: Int = 80,
        rows: Int = 24,
        ask: @escaping @Sendable (SSHHostKeyPrompt) async -> Bool
    ) {
        self.endpoint = host.endpoint
        self.username = host.username
        self.credential = credential
        self.knownHosts = knownHosts
        self.ask = ask
        self.shell = ShellHandle(columns: columns, rows: rows)

        let (events, emit) = AsyncStream<SSHSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1024)
        )
        let (commands, issue) = AsyncStream<SSHCommand>.makeStream()
        self.events = events
        self.emit = emit
        self.commands = commands
        self.issue = issue
    }

    public func connect() {
        Task { await self.run() }
    }

    public func send(_ data: Data) {
        issue.yield(.write(data))
    }

    /// Character cells, not pixels: zero in the character fields means "use the pixel fields", which is how a window loses its wrapping. Remembered for a shell not yet open.
    public func resize(columns: Int, rows: Int) {
        issue.yield(.resize(columns: columns, rows: rows))
    }

    public func close() {
        issue.yield(.close)
    }

    // MARK: - Files

    /// SFTP where the server offers it, a one-off `ls` where it does not (see ``SSHFileService``). Throws ``SSHSessionError/notConnected`` with no shell, and ``SSHSessionError/browse(_:)`` when the server said no. The answer carries the absolute path because the first request names none.
    public func listDirectory(at path: String) async throws -> SSHDirectory {
        guard case .listing(let directory) = try await browse(.list, at: path) else {
            throw SSHSessionError.browse("The server answered a listing request with a file.")
        }
        return directory
    }

    public func readFile(at path: String) async throws -> SSHFileContents {
        guard case .contents(let contents) = try await browse(.preview, at: path) else {
            throw SSHSessionError.browse("The server answered a file request with a folder.")
        }
        return contents
    }

    /// The whole file, not a patch (see ``SSHBrowseRequest/Kind/write(contents:)``): the editor enforces it by refusing to open a file whose read was cut short. Answers with contents so the caller shows the size the server actually holds.
    public func writeFile(_ contents: Data, to path: String) async throws -> SSHFileContents {
        guard case .written(let written) = try await browse(.write(contents: contents), at: path)
        else {
            throw SSHSessionError.browse("The server answered a write with something else.")
        }
        return written
    }

    /// One method because ``RemoteFileOperation`` is the unit both ends share, so the browser composes it once. Answers with a sentence because the caller re-lists the folder either way. Throws as ``browse`` does.
    @discardableResult
    public func change(_ operation: RemoteFileOperation) async throws -> String {
        // The path the operation is about, which the answer is keyed to, matching the Mac's `changeFile`.
        let path: String
        switch operation {
        case .create(let target, _), .rename(let target, _), .delete(let target):
            path = target
        }

        guard case .changed(let note) = try await browse(.change(operation), at: path) else {
            throw SSHSessionError.browse("The server answered a change with something else.")
        }
        return note
    }

    /// Two guards cover two windows. ``ShellHandle/isAttached`` catches a session still connecting or failed. The yield's own result catches the loop ending just before the shell detaches: a `yield` into a finished stream drops its `CheckedContinuation`, and one deallocated unresumed is a trap rather than a hang.
    // MARK: - Forwarding

    /// The client half of a local port forward: Citadel's `createDirectTCPIPChannel` does the rest, this asks for one from outside the task that owns the client. Answers with a wrapped channel so the wrapping happens on the right event loop before anything reads (see ``NIOAsyncChannel``, which drops reads otherwise). `localPort` is the originator the server logs. Throws ``SSHSessionError/notConnected`` or ``SSHSessionError/forward(_:)``.
    public func openDirectChannel(
        to host: String,
        port: Int,
        from localPort: Int
    ) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        guard isUp.value else { throw SSHSessionError.notConnected }

        return try await withCheckedThrowingContinuation { continuation in
            let request = SSHForwardRequest(
                host: host,
                port: port,
                localPort: localPort,
                continuation: continuation
            )
            if case .terminated = issue.yield(.forward(request)) {
                continuation.resume(throwing: SSHSessionError.notConnected)
            }
        }
    }

    private func browse(_ kind: SSHBrowseRequest.Kind, at path: String) async throws -> SSHBrowseResult {
        guard shell.isAttached else { throw SSHSessionError.notConnected }

        return try await withCheckedThrowingContinuation { continuation in
            let request = SSHBrowseRequest(kind: kind, path: path, continuation: continuation)
            if case .terminated = issue.yield(.browse(request)) {
                continuation.resume(throwing: SSHSessionError.notConnected)
            }
        }
    }

    /// Built here rather than stored: a key's authentication method holds a live signing key, which should not be held for the life of a screen that may never connect.
    private func authenticationMethod() throws -> SSHAuthenticationMethod {
        switch credential {
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .key(let pair):
            do {
                return try pair.authenticationMethod(username: username)
            } catch let error as SSHKeyError {
                // A transport failure from the screen's point of view: no shell opened, and the key's own sentence tells the user which half to fix.
                throw SSHSessionError.transport(error.message)
            }
        }
    }

    private func run() async {
        let store = self.knownHosts
        let delegate = SSHHostKeyValidator(
            endpoint: endpoint,
            store: store,
            ask: ask,
            record: { prompt, blob in
                _ = store.record(
                    endpoint: prompt.endpoint,
                    algorithm: prompt.algorithm,
                    publicKey: blob
                )
            }
        )

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: endpoint.hostname,
                port: endpoint.port,
                authenticationMethod: try authenticationMethod(),
                hostKeyValidator: .custom(delegate),
                // `.never`, not a default: Citadel's reconnect loop re-dials from its own close handler, an unbounded retry against a server that is down.
                reconnect: .never
            )
        } catch let error as SSHSessionError {
            emit.yield(.failed(error))
            emit.finish()
            return
        } catch {
            emit.yield(.failed(.transport(String(describing: error))))
            emit.finish()
            return
        }

        // Set before the shell is asked for: a forward is legitimate once there is a transport, and keyboard-interactive auth can take a second.
        isUp.value = true
        emit.yield(.connected)

        /// Nested because the client is a local of this task and does not leave it. The originator address is this phone's loopback port for the forward; `sshd` logs it, and a made-up value would lie about which tunnel a connection came through.
        func openDirectChannel(
            to host: String,
            port: Int,
            from localPort: Int
        ) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
            let originator = try SocketAddress(ipAddress: "127.0.0.1", port: localPort)
            let channel = try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(
                    targetHost: host,
                    targetPort: port,
                    originatorAddress: originator
                )
            ) { channel in
                // Nothing to add: `createDirectTCPIPChannel` already installed the codec that turns `SSHChannelData` into `ByteBuffer`.
                channel.eventLoop.makeSucceededVoidFuture()
            }

            // On the channel's own loop before anything can read from it: the async wrapping initialiser is one hop later, and a fast server's first bytes would be dropped.
            return try await channel.eventLoop.submit {
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }.get()
        }

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        let emit = self.emit
        let issue = self.issue
        let commands = self.commands
        let shell = self.shell

        do {
            try await client.withPTY(request) { inbound, outbound in
                let boxed = BoxedShell(inbound: inbound, outbound: outbound)
                await shell.attach(boxed)

                // Created here and never stored: it holds the client, which does not leave this task.
                let files = SSHFileService(client: client)

                let reader = Task {
                    do {
                        for try await chunk in boxed.inbound {
                            switch chunk {
                            case .stdout(let buffer), .stderr(let buffer):
                                emit.yield(.output(Data(buffer: buffer)))
                            }
                        }
                    } catch {
                        sessionLog.error("shell read ended: \(String(describing: error), privacy: .public)")
                    }
                    // The shell is over, so finishing the command stream is what lets the loop below stop.
                    issue.finish()
                }

                for await command in commands {
                    switch command {
                    case .write(let data):
                        do { try await shell.send(data) } catch { sessionLog.error("write failed") }
                    case .resize(let columns, let rows):
                        do { try await shell.resize(columns: columns, rows: rows) } catch { sessionLog.error("resize failed") }
                    case .browse(let request):
                        // Answered in line, the one place the terminal can stall: a task of its own cannot have the non-`Sendable` client, and an `@unchecked` box is a bad trade for one round trip.
                        await files.answer(request)
                    case .forward(let request):
                        // Answered in line for the same reason; the bytes are pumped outside by a task with only `Sendable` handles.
                        do {
                            let channel = try await openDirectChannel(
                                to: request.host,
                                port: request.port,
                                from: request.localPort
                            )
                            request.continuation.resume(returning: channel)
                        } catch {
                            request.continuation.resume(throwing: SSHSessionError.forward(error))
                        }
                    case .close:
                        break
                    }
                    if case .close = command { break }
                }

                // Finishing the stream here, before the shell is closed, means a late request is refused by the `yield` rather than sitting in a buffer and taking its continuation down.
                issue.finish()

                reader.cancel()
                _ = await reader.value
            }
        } catch {
            sessionLog.error("shell failed: \(String(describing: error), privacy: .public)")
        }

        shell.detach()
        try? await client.close()
        // Cleared before the events are, so a late dial is refused on the flag rather than sent into a stream nobody reads.
        isUp.value = false
        emit.yield(.closed)
        emit.finish()
        issue.finish()
    }
}
