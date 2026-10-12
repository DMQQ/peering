import Citadel
import Crypto
import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH
import RemoteCore
import os

let sessionLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

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
    /// The reader fell behind and the oldest events were discarded.
    case outputDropped
    case failed(SSHSessionError)
    case closed
}

/// Everything the connection owns is created inside the task that runs it: `SSHClient` is not `Sendable`, so the answer is confinement rather than an `@unchecked` box. Hence ``connect()`` cannot return the connection and failures are reported on ``events``.
public final class SSHSession: Sendable {
    public let events: AsyncStream<SSHSessionEvent>

    let emit: SSHEventSink
    let commands: AsyncStream<SSHCommand>
    let issue: AsyncStream<SSHCommand>.Continuation
    let shell: ShellHandle
    let isUp = SSHConnectionFlag()
    let isCloseRequested = SSHConnectionFlag()

    /// How long a file request may wait for the server before the caller is told it did not answer.
    static let browseTimeout = Duration.seconds(30)

    let endpoint: SSHEndpoint
    let username: String
    let credential: SSHCredential
    let knownHosts: SSHKnownHosts
    let ask: @Sendable (SSHHostKeyPrompt) async -> Bool

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
        self.emit = SSHEventSink(emit)
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

    /// Also covers a close that arrives while still connecting: `run` checks the flag once the dial returns, since Citadel's connect cannot be cancelled and gives up on its own after 15 seconds.
    public func close() {
        isCloseRequested.value = true
        issue.yield(.close)
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
                reconnect: .never,
                connectTimeout: .seconds(15)
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

        if isCloseRequested.value {
            try? await client.close()
            emit.yield(.closed)
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

                // The one task that touches `files` after this point, so the service needs no lock; the loop below only hands it requests.
                let (browseRequests, browseIssue) = AsyncStream<SSHBrowseRequest>.makeStream()
                let worker = SSHFileWorker(files)
                let browseWorker = Task {
                    for await request in browseRequests { await worker.service.answer(request) }
                }

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
                        // Queued for the worker above, so a server that never answers a file request cannot hold up keystrokes and resizes.
                        request.reply.expire(after: Self.browseTimeout)
                        browseIssue.yield(request)
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

                browseIssue.finish()
                browseWorker.cancel()
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
