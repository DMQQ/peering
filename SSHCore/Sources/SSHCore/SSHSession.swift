import Citadel
import Crypto
import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH
import RemoteCore
import os

private let sessionLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// A server's key, put in the form a screen can show before anyone has agreed to it.
///
/// The algorithm is carried beside the fingerprint rather than instead of it, because the two
/// answer different questions. The fingerprint is what the user checks against the machine by
/// another route; the algorithm is how a *change* is explained — a server that offered
/// `ssh-ed25519` last time and `rsa-sha2-256` now has a different fingerprint for a reason that is
/// not an attack, and a prompt showing only the hash would make that look like one.
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

/// Why a connection did not open, said in the terms the screen that reports it needs.
public enum SSHSessionError: Error, Sendable {
    /// Never seen this host, and the user declined. Carries the prompt so the screen can repeat
    /// what was shown — "you declined this key" is only useful next to the key.
    case hostKeyRejected(SSHHostKeyPrompt)
    /// A host already known offered a different key.
    ///
    /// Deliberately *not* reachable by agreeing to something: the connection fails here and the
    /// only way past is the known-hosts list. A one-tap "accept the new key" would be a button
    /// that turns the whole check into a formality, because the moment it matters is the moment
    /// the user is being hurried.
    case hostKeyChanged(known: KnownHost, presented: SSHHostKeyPrompt)
    /// The transport failed, or the server refused. The text is the underlying reason.
    case transport(String)
    /// Asked to write with no shell open, or after it ended.
    case notConnected
    /// A browse request could not be answered, with the reason in the terms the browser shows.
    ///
    /// Not a variant of ``transport``: nothing about the connection has necessarily gone wrong —
    /// a folder that is not there, a file that is not text and a server with no SFTP are all
    /// ordinary answers, and the panel that asked has a line to put them on.
    case browse(String)
}

/// What a session reports, in the order it happens.
public enum SSHSessionEvent: Sendable {
    /// The transport is up and the host key is settled; authentication is next.
    case connected
    /// Bytes from the server.
    ///
    /// stdout and stderr arrive as one stream: on a PTY the two are the same descriptor, and
    /// splitting them would mean inventing a distinction the server has already thrown away.
    case output(Data)
    /// The session ended for a reason. Nothing follows this event.
    case failed(SSHSessionError)
    /// The session ended. Nothing follows this event.
    case closed
}

/// The server's key, checked against what the app already knows.
///
/// A struct rather than a closure on the connect call, because the three outcomes are three
/// different behaviours and only one of them asks anybody anything: a known key succeeds silently,
/// a changed key fails outright, and a new one suspends the handshake on a human.
///
/// That suspension is why this is not a simple boolean. `validateHostKey` is called from NIO's
/// event loop and must answer through a promise, so the asking happens in a `Task` and the promise
/// is completed whenever the user gets to it. The server waits mid-handshake, which is exactly
/// right: nothing has been sent that assumes a trusted peer yet.
struct SSHHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let endpoint: SSHEndpoint
    let store: SSHKnownHosts
    /// Asks about a host never seen before. Returns whether the user agreed.
    let ask: @Sendable (SSHHostKeyPrompt) async -> Bool
    /// Called once a first-sight key has been both shown and accepted.
    let record: @Sendable (SSHHostKeyPrompt, Data) -> Void

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // The blob is what OpenSSH hashes, and `write(to:)` is the only way to get it byte-exact.
        // Deriving it instead from `String(openSSHPublicKey:)` would produce the same base64 today
        // and be one refactor away from a different one — a fingerprint that no longer matches
        // `ssh-keygen -lf`, and so one nobody can check.
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        hostKey.write(to: &buffer)
        let blob = Data(buffer: buffer)

        // `keyPrefix` is internal to NIOSSH, so the algorithm is read back off the OpenSSH
        // rendering — `"ssh-ed25519 AAAAC3..."` — rather than off the type.
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

/// A live shell's two ends.
///
/// Boxed so they can be moved into the tasks that run them. `TTYOutput` and `TTYStdinWriter` are
/// both thin handles over one NIO `Channel`, and NIO channels are safe to read and write from any
/// thread — the event loop serialises them, and every method on both types is a `writeAndFlush` or
/// a read of that channel. Citadel does not declare either `Sendable`, because they are public
/// structs and public conformance is not inferred across modules. The conformance is asserted
/// here, once, beside the reason, rather than at each call site.
struct BoxedShell: @unchecked Sendable {
    let inbound: TTYOutput
    let outbound: TTYStdinWriter
}

/// The stdin end, reachable from outside the task that owns the connection.
///
/// A lock rather than actor state, and the reason is the compiler's: `TTYStdinWriter` is not
/// `Sendable`, so it cannot be stored in an actor at all — reading it back out is itself a
/// "sending" error. A lock-protected box keeps it in one place and hands out no reference.
private final class ShellHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var boxed: BoxedShell?
    private var columns: Int
    private var rows: Int

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    /// Every read and write of the guarded state goes through one of these four, and none is
    /// `async` — `NSLock` may not be held across a suspension point, so the lock lives in a
    /// synchronous helper rather than in the async method that wants the value. Keeping the whole
    /// critical section synchronous is also what makes it critical: an `await` inside it would let
    /// another command in between the read and the write.
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

    /// Takes the shell, and applies a size that was chosen before it existed.
    func attach(_ shell: BoxedShell) async {
        _ = swap(shell)
        // A resize the user made while the connection was still opening is not dropped — the
        // server is told about it as soon as there is anything to tell.
        let (cols, rowCount) = size()
        try? await shell.outbound.changeSize(cols: cols, rows: rowCount, pixelWidth: 0, pixelHeight: 0)
    }

    func detach() {
        _ = swap(nil)
    }

    /// Whether a shell is attached right now.
    ///
    /// Read by browse requests, and it is the difference between a refusal and a crash: the
    /// command loop is the only thing that can answer one, and a request yielded with no loop
    /// running sits in the stream's buffer holding a continuation that nothing will ever resume.
    /// It covers the two windows that last seconds rather than microseconds, which are the ones
    /// worth covering: a session still connecting, and one whose connection failed before a shell
    /// ever opened. The rest is caught by the yield itself, see ``SSHSession/browse(_:at:)``.
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

/// The input a session accepts from its caller.
private enum SSHCommand: Sendable {
    case write(Data)
    case resize(columns: Int, rows: Int)
    /// Something to do with the server's files. A question rather than a message, which is why it
    /// carries a continuation out: see ``SSHBrowseRequest``.
    case browse(SSHBrowseRequest)
    case close
}

/// One interactive shell on one server.
///
/// Everything the connection owns is created *inside* the task that runs it and never leaves:
/// `SSHClient` is a mutable class that Citadel does not declare `Sendable`, and the honest answer
/// to that is not an `@unchecked` box but confinement. So the client is a local of ``run()``, the
/// caller side holds only sendable things — two continuations and a lock-protected stdin — and
/// nothing that is not `Sendable` crosses an isolation boundary in either direction.
///
/// The cost is the shape of the API: ``connect()`` cannot return the connection, so failures are
/// reported on ``events`` rather than thrown. For a terminal that is the better contract anyway —
/// the screen is already open and showing "connecting", and an error has somewhere to land.
public final class SSHSession: Sendable {
    public let events: AsyncStream<SSHSessionEvent>

    private let emit: AsyncStream<SSHSessionEvent>.Continuation
    private let commands: AsyncStream<SSHCommand>
    private let issue: AsyncStream<SSHCommand>.Continuation
    private let shell: ShellHandle

    private let endpoint: SSHEndpoint
    private let username: String
    private let password: String
    private let knownHosts: SSHKnownHosts
    private let ask: @Sendable (SSHHostKeyPrompt) async -> Bool

    public init(
        host: SSHHost,
        password: String,
        knownHosts: SSHKnownHosts = SSHKnownHosts(),
        columns: Int = 80,
        rows: Int = 24,
        ask: @escaping @Sendable (SSHHostKeyPrompt) async -> Bool
    ) {
        self.endpoint = host.endpoint
        self.username = host.username
        self.password = password
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

    /// Opens the connection and starts the shell. Returns immediately.
    public func connect() {
        Task { await self.run() }
    }

    /// Sends bytes to the shell — a keystroke, pasted text, a control character.
    public func send(_ data: Data) {
        issue.yield(.write(data))
    }

    /// Tells the server the window changed shape, and remembers it for a shell not yet open.
    ///
    /// Character cells, not pixels: the request carries both, and a terminal that reports columns
    /// and rows is one the remote `vim` can lay out. Zero in the character fields means "use the
    /// pixel fields", which is how a window loses its wrapping.
    public func resize(columns: Int, rows: Int) {
        issue.yield(.resize(columns: columns, rows: rows))
    }

    /// Ends the session. Safe to call more than once, and on one that never opened.
    public func close() {
        issue.yield(.close)
    }

    // MARK: - Files

    /// One folder's contents, from the server the shell is on.
    ///
    /// The answer carries the folder's absolute path, because the first request of a browser does
    /// not name one: it asks about the directory a login starts in, which only the server can turn
    /// into a path, and every request after that is built from an answer and arrives absolute.
    ///
    /// SFTP where the server offers it, and a one-off `ls` where it does not — see
    /// ``SSHFileService``, which settles on one of the two per session.
    ///
    /// Throws ``SSHSessionError/notConnected`` when there is no shell to ask through, and
    /// ``SSHSessionError/browse(_:)`` when the server answered and the answer was no.
    public func listDirectory(at path: String) async throws -> SSHDirectory {
        guard case .listing(let directory) = try await browse(.list, at: path) else {
            throw SSHSessionError.browse("The server answered a listing request with a file.")
        }
        return directory
    }

    /// A file's text, for the browser's preview.
    ///
    /// SFTP only: see ``SSHFileService/contents(at:)`` for why a server without it browses and
    /// does not preview.
    public func readFile(at path: String) async throws -> SSHFileContents {
        guard case .contents(let contents) = try await browse(.preview, at: path) else {
            throw SSHSessionError.browse("The server answered a file request with a folder.")
        }
        return contents
    }

    /// Replaces a file with the bytes given, and answers with what the server now holds.
    ///
    /// **The whole file, not a patch.** See ``SSHBrowseRequest/Kind/write(contents:)`` — the caller
    /// hands over everything the file should contain, and everything not handed over is gone. The
    /// editor is what enforces that, by refusing to open a file whose read was cut short; a caller
    /// writing an upload is handing over a whole file by construction.
    ///
    /// Answers with contents rather than a bare acknowledgement so the caller can show the size the
    /// server actually ended up with, rather than the one it hoped for.
    public func writeFile(_ contents: Data, to path: String) async throws -> SSHFileContents {
        guard case .written(let written) = try await browse(.write(contents: contents), at: path)
        else {
            throw SSHSessionError.browse("The server answered a write with something else.")
        }
        return written
    }

    /// Makes, renames or removes something, and answers with what to say about it.
    ///
    /// One method rather than three, because the operation is already the unit the phone builds
    /// and the two ends share: the same ``RemoteFileOperation`` value goes out over the control
    /// channel to a Mac and down this path to a server, so the browser composes it once and
    /// whichever machine answers does so in the same terms.
    ///
    /// Answers with the sentence rather than with the thing it acted on, because what the caller
    /// does next is re-list the folder either way — the same move an upload makes, and for the
    /// same reason: asking again is cheaper to get right than patching one entry into a list that
    /// may have changed in other ways too.
    ///
    /// Throws ``SSHSessionError/notConnected`` when there is no shell to ask through, and
    /// ``SSHSessionError/browse(_:)`` when the server answered and the answer was no.
    @discardableResult
    public func change(_ operation: RemoteFileOperation) async throws -> String {
        // The path the operation is about, which is the one the answer is keyed to — the same
        // value the Mac's own `changeFile` echoes back, so both ends answer alike.
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

    /// Asks the command loop something, and waits for it to answer.
    ///
    /// The two guards around the `yield` are the whole of the safety here, and they cover two
    /// different windows. ``ShellHandle/isAttached`` catches the long one — a session still
    /// connecting, and one whose connection failed, neither of which has a loop and either of
    /// which would otherwise leave the request in the stream's buffer for the life of the object.
    /// The yield's own result catches the short one: the loop ends, the shell detaches a moment
    /// later, and a request that lands in between goes into a stream nothing is reading. A
    /// `yield` into a finished stream drops what it was given, which here would drop a
    /// `CheckedContinuation` on the floor — and one of those deallocated without being resumed is
    /// a trap rather than a hang, which is the right severity for a bug that would otherwise be
    /// invisible until a user's phone crashed.
    private func browse(_ kind: SSHBrowseRequest.Kind, at path: String) async throws -> SSHBrowseResult {
        guard shell.isAttached else { throw SSHSessionError.notConnected }

        return try await withCheckedThrowingContinuation { continuation in
            let request = SSHBrowseRequest(kind: kind, path: path, continuation: continuation)
            if case .terminated = issue.yield(.browse(request)) {
                continuation.resume(throwing: SSHSessionError.notConnected)
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
                // Reached only from the first-sight path, which is the only path that asks.
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
                authenticationMethod: .passwordBased(username: username, password: password),
                hostKeyValidator: .custom(delegate),
                // `.never`, and not as a default. Citadel's reconnect loop re-dials from inside its
                // own close handler; against a server that is simply down that is an unbounded
                // retry, and whether to try again is the screen's decision, not the transport's.
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

        emit.yield(.connected)

        // Held only so this task can close it, and only ever touched from here.
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

                // The folder tree, over the connection this shell is already on. Created here and
                // never stored, for the reason this whole method is shaped the way it is: it holds
                // the client, and the client does not leave this task.
                let files = SSHFileService(client: client)

                // The server's output, drained on its own task so the command loop below can run
                // at the same time — a shell that is only ever written to is a shell that never
                // shows anything.
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
                    // The shell is over, so no further command can be answered. Finishing the
                    // command stream is what lets the loop below stop; without it this task would
                    // sit waiting on input for a session that has already ended.
                    issue.finish()
                }

                for await command in commands {
                    switch command {
                    case .write(let data):
                        do { try await shell.send(data) } catch { sessionLog.error("write failed") }
                    case .resize(let columns, let rows):
                        do { try await shell.resize(columns: columns, rows: rows) } catch { sessionLog.error("resize failed") }
                    case .browse(let request):
                        // Answered here, in line, and this is the one place the terminal can stall:
                        // a keystroke typed while a folder is being read waits for it. The
                        // alternative is a task of its own, and a task of its own cannot have the
                        // client — it is not `Sendable`, which is the whole reason everything in
                        // this method lives inside this closure — and an `@unchecked` box around
                        // a live connection to buy concurrency for a folder read is a bad trade
                        // at any price. One folder is one round trip on a connection that is
                        // already open; a stall that short is not worth the box.
                        await files.answer(request)
                    case .close:
                        break
                    }
                    if case .close = command { break }
                }

                // The loop is the only thing that can answer a browse request, so once it is over
                // there is nothing left to answer one with. Finishing the stream here rather than
                // after the shell is closed is what makes that true for the last few microseconds
                // of a session as well as all the rest of it: a request that arrives from now on
                // is refused by the `yield`, rather than sitting in a buffer until the session is
                // deallocated and taking its continuation down with it.
                issue.finish()

                reader.cancel()
                _ = await reader.value
            }
        } catch {
            sessionLog.error("shell failed: \(String(describing: error), privacy: .public)")
        }

        shell.detach()
        try? await client.close()
        emit.yield(.closed)
        emit.finish()
        issue.finish()
    }
}
