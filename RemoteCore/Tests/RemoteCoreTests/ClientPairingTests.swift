import CryptoKit
import Foundation
import Network
import Security
import Testing

@testable import RemoteCore

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

struct TestSetupError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The probe key carries its own tag and is destroyed at once, so it neither reads nor mints the app identity.
let keychainIsUsable: Bool = {
    let tag = Data("pl.dmq.maccast.tests.keychain-probe.\(UUID().uuidString)".utf8)
    defer { try? SelfSignedIdentity.destroy(role: .client, keyTag: tag) }
    let identity = try? SelfSignedIdentity.loadOrCreate(
        role: .client,
        commonName: "Keychain probe",
        keyTag: tag
    )
    return identity != nil
}()

/// **The tag is the whole point.** `loadOrCreate` defaults to a fixed tag belonging to the real
/// app, so a test that let it default would load the developer's own key and the teardown here
/// would then delete it. A fresh tag per identity keeps the two apart in both directions, which is
/// a mistake this project has already made once from a probe, in the other direction.
func withIdentity<T>(
    role: SelfSignedIdentity.Role,
    commonName: String,
    _ body: (SelfSignedIdentity) async throws -> T
) async throws -> T {
    let tag = Data("pl.dmq.maccast.tests.identity.\(UUID().uuidString)".utf8)
    let identity = try SelfSignedIdentity.loadOrCreate(role: role, commonName: commonName, keyTag: tag)
    defer { try? SelfSignedIdentity.destroy(role: role, keyTag: tag) }
    return try await body(identity)
}

func withTestEnds<T>(
    _ body: (_ client: SelfSignedIdentity, _ mac: SelfSignedIdentity) async throws -> T
) async throws -> T {
    try await withIdentity(role: .client, commonName: "Test iPhone") { client in
        try await withIdentity(role: .server, commonName: "Scripted Mac") { mac in
            try await body(client, mac)
        }
    }
}

/// Fresh account per test so parallel tests cannot see each other's pins; teardown deletes the item rather than leaving the empty one `removeAll()` writes.
struct TestPins {
    let store: ClientPinStore
    private let service = "pl.dmq.maccast.tests.clientpins"
    private let account: String

    init() {
        account = UUID().uuidString
        store = ClientPinStore(service: service, account: account)
    }

    func destroy() {
        _ = store.removeAll()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class SessionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ClientSession.Event] = []

    private var failureWaiters: [CheckedContinuation<String, Never>] = []

    func record(_ event: ClientSession.Event) {
        let (waiters, message): ([CheckedContinuation<String, Never>], String?) = lock.withLock {
            events.append(event)
            guard let message = failureLocked else { return ([], nil) }
            defer { failureWaiters = [] }
            return (failureWaiters, message)
        }
        // Resumed after the lock is released: a continuation must not run while the log is held.
        if let message { waiters.forEach { $0.resume(returning: message) } }
    }

    /// The failure, waiting for it if the session has not emitted it yet: `connect` can return before the event is delivered when the machine is busy.
    func awaitFailure() async -> String {
        await withCheckedContinuation { waiter in
            let known: String? = lock.withLock {
                if let message = failureLocked { return message }
                failureWaiters.append(waiter)
                return nil
            }
            if let known { waiter.resume(returning: known) }
        }
    }

    private var failureLocked: String? {
        for case .phase(.failed(let message)) in events.reversed() { return message }
        return nil
    }

    var phases: [ClientSession.Phase] {
        lock.withLock {
            events.compactMap { if case .phase(let phase) = $0 { return phase } else { return nil } }
        }
    }

    var notes: [String] {
        lock.withLock {
            events.compactMap { if case .note(let text) = $0 { return text } else { return nil } }
        }
    }

    var failure: String? {
        for phase in phases.reversed() {
            if case .failed(let message) = phase { return message }
        }
        return nil
    }

    var isReady: Bool { phases.contains(.ready) }

    var confirmingCode: String? {
        for phase in phases.reversed() {
            if case .confirming(let code) = phase { return code }
        }
        return nil
    }

    func wait(within seconds: TimeInterval = 10, until condition: (SessionLog) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition(self) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition(self)
    }
}

final class ScriptedMac: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.scripted-mac")
    private let lock = NSLock()
    private var accepted: [MacLink] = []

    init(identity: SelfSignedIdentity) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(
            tls: try TLSConfig.serverOptions(identity: identity, queue: queue),
            tcp: tcp
        )
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            let link = MacLink(connection)
            // Started here rather than when the test takes it, and that is load bearing: a
            // connection a listener hands over is not started for you, and until it is the TLS
            // handshake the client is waiting on has nothing to talk to. Starting it on the way
            // out of `nextConnection` would be a deadlock with the client's own connect, which
            // does not return until that handshake finishes.
            link.start()
            self.lock.withLock { self.accepted.append(link) }
        }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func start() async {
        await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    guard !resumed.value else { return }
                    resumed.set()
                    continuation.resume()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    /// A session that reaches ready opens a second socket for video, so this takes them in the
    /// order they arrive and the callers that only care about the control channel take the first.
    func nextConnection(within seconds: TimeInterval = 10) async -> MacLink? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let link = take() {
                await link.waitUntilReady()
                return link
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func take() -> MacLink? {
        lock.lock()
        defer { lock.unlock() }
        return accepted.isEmpty ? nil : accepted.removeFirst()
    }
}

final class MacLink: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.scripted-mac.link")
    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var arrived: [Frame] = []
    private var ready = false
    private var ended = false
    private var failureReason: String?
    private var readyWaiter: CheckedContinuation<Void, Never>?

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.becameReady()
            case .failed(let error): self.end(reason: "\(error)")
            case .cancelled: self.end(reason: "the client cancelled the connection")
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    /// The same wait `RelayByteSpliceTests` makes, for the same reason: a `send` on a connection
    /// that is still setting up is accepted and then dropped, which here would be a scripted Mac
    /// that answered nothing and a test that failed for a reason it could not name.
    func waitUntilReady() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if ready || ended {
                lock.unlock()
                continuation.resume()
            } else {
                readyWaiter = continuation
                lock.unlock()
            }
        }
    }

    private func becameReady() {
        lock.lock()
        ready = true
        let waiter = readyWaiter
        readyWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    private func end(reason: String? = nil) {
        lock.lock()
        ended = true
        if let reason, failureReason == nil { failureReason = reason }
        let waiter = readyWaiter
        readyWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    // MARK: - Sending

    func send(_ frame: Frame) {
        connection.send(content: FrameEncoder.encode(frame), completion: .contentProcessed { _ in })
    }

    func send<T: Encodable>(_ kind: MessageKind, _ value: T) {
        guard let payload = try? MessageCodec.encode(value) else { return }
        send(Frame(kind: kind, payload: payload))
    }

    /// **The difference from `ClientSession.disconnect()` is the whole reason this exists.** The
    /// client's own teardown closes its sockets as *cancelled*, and a cancelled socket must not be
    /// dialled again; a socket this end closed arrives as a transport failure, which is what the
    /// video reconnect is armed by. A test that could only close sockets from the client's side
    /// could not tell those two apart.
    /// The reason is written before the cancel, because `end` keeps the first one and the
    /// cancellation path names itself as the client's doing.
    func hangUp() {
        lock.withLock { if failureReason == nil { failureReason = "this Mac hung up" } }
        connection.cancel()
    }

    func sendHello(serverID: String, alreadyPaired: Bool) {
        send(.serverHello, ServerHello(
            serverID: serverID,
            hostName: "Scripted Mac",
            protocolVersion: ProtocolInfo.version,
            alreadyPaired: alreadyPaired
        ))
    }

    // MARK: - Receiving

    func next(within seconds: TimeInterval = 10) async -> Frame? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let frame = dequeue() { return frame }
            if hasEnded() { return nil }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return dequeue()
    }

    /// Checked rather than skipped: what a handshake *is* is the order of these frames, and a
    /// helper that discarded anything unexpected would pass against a client that sent them in the
    /// wrong order. It throws rather than recording, so a test stops at the first frame that was
    func expect(_ kind: MessageKind, within seconds: TimeInterval = 10) async throws -> Frame {
        guard let frame = await next(within: seconds) else {
            let why = lock.withLock { failureReason } ?? "the connection is still open"
            throw TestSetupError("the client sent nothing where \(kind) was expected (\(why))")
        }
        guard frame.kind == kind else {
            throw TestSetupError("expected \(kind) from the client, got \(frame.kind)")
        }
        return frame
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            if isComplete || error != nil { self.end(); return }
            self.receive()
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        decoder.append(data)
        do {
            while let frame = try decoder.next() { arrived.append(frame) }
        } catch {
            ended = true
        }
    }

    private func dequeue() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        return arrived.isEmpty ? nil : arrived.removeFirst()
    }

    private func hasEnded() -> Bool { lock.withLock { ended } }
}

@discardableResult
func greet(_ link: MacLink, serverID: String, alreadyPaired: Bool) async throws -> ClientHello {
    let role = try await link.expect(.connectionRole)
    #expect(
        role.payload == Data([ConnectionRole.control.rawValue]),
        "the first frame has to say which channel this connection is"
    )
    let frame = try await link.expect(.clientHello)
    let hello = try MessageCodec.decode(ClientHello.self, from: frame.payload)
    #expect(hello.protocolVersion == ProtocolInfo.version)
    link.sendHello(serverID: serverID, alreadyPaired: alreadyPaired)
    return hello
}

/// **Both surfaces, not just the event.** A failure during connect reaches the session twice: once
/// from the catch around the connect call, and once from the connection's own close. The first of
/// those to arrive is emitted as an event and the second overwrites `phase` in silence, so which
/// one a reader sees depends on which arrived first. A test that read only the events would be
func failurePhase(_ session: ClientSession) -> String? {
    if case .failed(let message) = session.phase { return message }
    return nil
}

private func loopback(_ port: UInt16) throws -> NWEndpoint {
    guard let port = NWEndpoint.Port(rawValue: port) else {
        throw TestSetupError("\(port) is not a usable TCP port")
    }
    return .hostPort(host: "127.0.0.1", port: port)
}

/// The pause after the cancel is not tidiness. `cancel()` closes the listening socket on the
/// listener's own queue, and a dial that beats it reaches a socket still in the backlog that
/// nothing will ever accept, which is a connection that hangs rather than one that is refused.
private func unusedLoopbackPort() async throws -> UInt16 {
    let options = NWProtocolTCP.Options()
    options.noDelay = true
    let listener = try NWListener(using: NWParameters(tls: nil, tcp: options), on: .any)
    // Nothing should ever connect to this, and the handler is still not optional: a listener with
    // no `newConnectionHandler` refuses to start on this macOS, failing with `EINVAL`, which reads
    // as a bad port number and is not one.
    listener.newConnectionHandler = { connection in connection.cancel() }
    let settled = await withCheckedContinuation { continuation in
        let resumed = LockedFlag()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                guard !resumed.value else { return }
                resumed.set()
                continuation.resume(returning: "\(state)")
            default:
                break
            }
        }
        listener.start(queue: DispatchQueue(label: "test.unused-port"))
    }
    let port = listener.port?.rawValue ?? 0
    listener.cancel()
    guard port != 0 else { throw TestSetupError("could not take a loopback port (the listener said \(settled))") }
    try await Task.sleep(for: .milliseconds(100))
    return port
}

let transportSentences: Set<String> = [
    NetworkFailureText.describe(POSIXErrorCode.ECONNREFUSED),
    NetworkFailureText.describe(POSIXErrorCode.ECONNRESET),
    NetworkFailureText.describe(POSIXErrorCode.ETIMEDOUT),
    NetworkFailureText.describe(POSIXErrorCode.EHOSTUNREACH),
    NetworkFailureText.describe(POSIXErrorCode.ENETUNREACH),
    NetworkFailureText.describe(POSIXErrorCode.EHOSTDOWN),
    NetworkFailureText.describe(POSIXErrorCode.EPIPE),
    NetworkFailureText.describe(POSIXErrorCode.ENETDOWN),
    ClientConnection.Failure.timedOut(5).errorDescription ?? "",
    ClientConnection.Failure.hostClosed.errorDescription ?? "",
    "The connection to the Mac failed.",
]

/// Serialized: two suites minting keys at once make `SecKeyCreateRandomKey` fail with `errSecItemNotFound`. The trait covers nested suites, which is why the video socket tests are nested.
@Suite("The client against a scripted Mac", .serialized, .timeLimit(.minutes(1)), .enabled(if: keychainIsUsable))
struct ClientPairingTests {
    /// Ending an attempt is the terminal event for that attempt. The transport's cancellation
    /// races the suspended `connect` call as it unwinds; if the latter is allowed to report its
    /// error afterwards, a user-requested disconnect turns into a failure card and can arm the
    /// reconnect ladder again.
    @Test func disconnectWhileConnectingCannotFailAfterwards() async throws {
        let pins = TestPins()
        defer { pins.destroy() }

        try await withTestEnds { client, macIdentity in
            let mac = try ScriptedMac(identity: macIdentity)
            await mac.start()
            defer { mac.stop() }

            let log = SessionLog()
            let session = ClientSession(
                identity: client,
                clientID: "phone-1",
                clientName: "Test iPhone",
                pins: pins.store,
                onEvent: { log.record($0) }
            )

            let attempt = Task {
                await session.connect(
                    to: .address(host: "127.0.0.1", port: mac.port),
                    timeout: 10
                )
            }
            let began = await log.wait { $0.phases.contains(.connecting) }
            #expect(began, "the connection attempt never began")

            session.disconnect()
            await attempt.value

            #expect(session.phase == .disconnected)
            #expect(log.phases.last == .disconnected)
            #expect(log.failure == nil, "the cancelled attempt reported a later failure")
        }
    }

    /// **The regression, and the most valuable assertion in this file.** A Mac that is not there
    /// must not be reported as a Mac whose identity changed. Dialled with a pin in force, as a paired Mac is: the old path keyed the identity failure on `pinned != nil`.
    /// matters: the old connect path asked whether a pin was *in force* (`pinned != nil`), decided
    /// on that basis that the Mac's identity was the problem, and told the user to break a working
    /// pairing over a sleeping Mac. A test that dialled an address would have had no pin in force
    /// and would have passed against the bug.
    @Test(.timeLimit(.minutes(1))) func aMacThatIsNotThereIsNotAnIdentityFailure() async throws {
        let pins = TestPins()
        defer { pins.destroy() }

        let hostID = "paired-mac"
        let pinnedKey = Data([0x04] + [UInt8](repeating: 0x22, count: 64))
        #expect(pins.store.record(hostID: hostID, publicKey: pinnedKey), "the pin could not be stored")

        let port = try await unusedLoopbackPort()
        let host = DiscoveredHost(
            id: hostID,
            name: "Damian's MacBook",
            endpoint: try loopback(port),
            protocolVersion: ProtocolInfo.version,
            interfaceCount: 1
        )

        try await withIdentity(role: .client, commonName: "Test iPhone") { identity in
            let log = SessionLog()
            let session = ClientSession(
                identity: identity,
                clientID: "phone-1",
                clientName: "Test iPhone",
                pins: pins.store,
                onEvent: { log.record($0) }
            )
            defer { session.disconnect() }

            await session.connect(to: .discovered(host), timeout: 5)

            let emitted = await log.awaitFailure()
            let reported = try #require(failurePhase(session), "the session's phase is not a failure")

            for message in [emitted, reported] {
                #expect(
                    transportSentences.contains(message),
                    "not a sentence the network table produces: \(message)"
                )
                #expect(
                    !message.contains("pinned"),
                    "a Mac that is asleep reads as an identity change: \(message)"
                )
                #expect(
                    !message.contains("paired with"),
                    "a Mac that is asleep reads as an identity change: \(message)"
                )
                #expect(
                    !message.contains("pair again"),
                    "a Mac that is asleep tells the user to break a working pairing: \(message)"
                )
            }

            #expect(emitted == reported)

            #expect(pins.store.pin(for: hostID) == pinnedKey)
        }
    }

    /// **The decision itself, in the direction that refuses.** A Mac whose certificate key is not
    /// the pinned one is a pin mismatch, in the words that carry the way out.
    /// Dialled by address, deliberately. An address says nothing about which Mac is at it, so the
    /// client brings no pin *to the TLS handshake* and the comparison is left where it is being
    /// tested, in `handleServerHello`. A Bonjour target pins inside the verify block, where a
    /// mismatch fails the handshake before any of this runs, and the session would never reach the
    /// sentence this test is about.
    @Test func aMacWhoseKeyIsNotThePinnedOneIsAPinMismatch() async throws {
        let pins = TestPins()
        defer { pins.destroy() }

        try await withTestEnds { client, macIdentity in
            let hostID = "paired-mac"
            let pinnedKey = Data([0x04] + [UInt8](repeating: 0x11, count: 64))
            #expect(pins.store.record(hostID: hostID, publicKey: pinnedKey), "the pin could not be stored")

            let mac = try ScriptedMac(identity: macIdentity)
            await mac.start()
            defer { mac.stop() }

            let log = SessionLog()
            let session = ClientSession(
                identity: client,
                clientID: "phone-1",
                clientName: "Test iPhone",
                pins: pins.store,
                onEvent: { log.record($0) }
            )
            defer { session.disconnect() }

            await session.connect(to: .address(host: "127.0.0.1", port: mac.port), timeout: 10)
            let link = try #require(await mac.nextConnection(), "the client never connected")
            _ = try await greet(link, serverID: hostID, alreadyPaired: true)

            let refused = await log.wait { $0.failure != nil }
            #expect(refused, "the session accepted a Mac whose key is not the one it pinned")

            let message = try #require(log.failure)
            #expect(message == ClientSession.Failure.pinMismatch(hostID: hostID).errorDescription)
            #expect(failurePhase(session) == message)
            #expect(session.failureReason == .pinMismatch)
            #expect(message.contains("not the Mac you paired with"))
            #expect(message.contains("pinned"))
            #expect(message.contains("pair again"))

            #expect(pins.store.pin(for: hostID) == pinnedKey)

            #expect(session.serverKey == macIdentity.publicKeyBytes)
        }
    }

    @Test func anUnpinnedMacClaimingAlreadyPairedIsRefusedNotPinned() async throws {
        let pins = TestPins()
        defer { pins.destroy() }

        try await withTestEnds { client, macIdentity in
            let hostID = "claimed-mac"
            let mac = try ScriptedMac(identity: macIdentity)
            await mac.start()
            defer { mac.stop() }

            let log = SessionLog()
            let session = ClientSession(
                identity: client,
                clientID: "phone-1",
                clientName: "Test iPhone",
                pins: pins.store,
                onEvent: { log.record($0) }
            )
            defer { session.disconnect() }

            await session.connect(to: .address(host: "127.0.0.1", port: mac.port), timeout: 10)
            let link = try #require(await mac.nextConnection(), "the client never connected")
            _ = try await greet(link, serverID: hostID, alreadyPaired: true)

            #expect(await log.wait { $0.failure != nil })
            #expect(session.failureReason == .noPinOnFile)
            #expect(pins.store.pin(for: hostID) == nil)
        }
    }

    @Test func aMacWhoseKeyMatchesThePinIsLetThrough() async throws {
        let pins = TestPins()
        defer { pins.destroy() }

        try await withTestEnds { client, macIdentity in
            let hostID = "paired-mac"
            #expect(
                pins.store.record(hostID: hostID, publicKey: macIdentity.publicKeyBytes),
                "the pin could not be stored"
            )

            let mac = try ScriptedMac(identity: macIdentity)
            await mac.start()
            defer { mac.stop() }

            let log = SessionLog()
            let session = ClientSession(
                identity: client,
                clientID: "phone-1",
                clientName: "Test iPhone",
                pins: pins.store,
                onEvent: { log.record($0) }
            )
            defer { session.disconnect() }

            await session.connect(to: .address(host: "127.0.0.1", port: mac.port), timeout: 10)
            let link = try #require(await mac.nextConnection(), "the client never connected")
            _ = try await greet(link, serverID: hostID, alreadyPaired: true)

            let ready = await log.wait { $0.isReady }
            #expect(ready, "the session did not get past the pin check")
            #expect(
                log.notes.contains("The Mac's key matches the pin stored for it."),
                "the pin was accepted without the check being reported: \(log.notes)"
            )

            #expect(session.serverKey == macIdentity.publicKeyBytes)
            #expect(pins.store.pin(for: hostID) == macIdentity.publicKeyBytes)
        }
    }

    /// A first pairing stores the key the Mac presented in its certificate, and both ends derive the same six digits from the transcript.
    @Test func aFirstPairingPinsTheKeyTheMacPresented() async throws {
        let pins = TestPins()
        defer { pins.destroy() }

        try await withTestEnds { client, macIdentity in
            let hostID = "unpaired-mac"
            #expect(pins.store.isEmpty, "this Mac is meant to be a stranger to this device")

            let mac = try ScriptedMac(identity: macIdentity)
            await mac.start()
            defer { mac.stop() }

            let log = SessionLog()
            let session = ClientSession(
                identity: client,
                clientID: "phone-1",
                clientName: "Test iPhone",
                pins: pins.store,
                onEvent: { log.record($0) }
            )
            defer { session.disconnect() }

            await session.connect(to: .address(host: "127.0.0.1", port: mac.port), timeout: 10)
            let link = try #require(await mac.nextConnection(), "the client never connected")
            let hello = try await greet(link, serverID: hostID, alreadyPaired: false)
            #expect(hello.wantsPairing, "a device with nothing pinned for this Mac should be asking to pair")
            #expect(pins.store.pin(for: hostID) == nil)

            // The Mac's commitment goes out before the client's is read and its reveal only after:
            // before rather than after, because a commitment made after seeing the other side's
            // contribution is not a commitment at all.
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            link.send(.pairCommit, PairingCommit(commitment: PairingSAS.commitment(
                ephemeralPublicKey: ephemeral.publicKey.x963Representation,
                nonce: nonce
            )))

            let clientCommit = try MessageCodec.decode(
                PairingCommit.self,
                from: try await link.expect(.pairCommit).payload
            )
            let clientReveal = try MessageCodec.decode(
                PairingReveal.self,
                from: try await link.expect(.pairReveal).payload
            )
            #expect(
                PairingSAS.verify(
                    commitment: clientCommit.commitment,
                    ephemeralPublicKey: clientReveal.ephemeralPublicKey,
                    nonce: clientReveal.nonce
                ),
                "the client's reveal does not match the commitment it made first"
            )

            let transcript = PairingTranscript(
                protocolVersion: ProtocolInfo.version,
                clientID: hello.clientID,
                serverID: hostID,
                clientEphemeralPublicKey: clientReveal.ephemeralPublicKey,
                serverEphemeralPublicKey: ephemeral.publicKey.x963Representation,
                clientNonce: clientReveal.nonce,
                serverNonce: nonce,
                serverIdentityPublicKey: macIdentity.publicKeyBytes
            )
            let macCode = PairingSAS.code(for: transcript)
            link.send(.pairReveal, PairingReveal(
                ephemeralPublicKey: ephemeral.publicKey.x963Representation,
                nonce: nonce
            ))

            let asked = await log.wait { $0.confirmingCode != nil }
            #expect(asked, "the client never reached the comparison the user makes")
            #expect(
                log.confirmingCode == macCode,
                "the two ends derived different digits from one exchange"
            )

            session.confirmPairing(accepted: true)
            _ = try await link.expect(.pairConfirm)
            link.send(.pairResult, PairResult(accepted: true))

            let paired = await log.wait { $0.isReady }
            #expect(paired, "the Mac accepted the pairing and the session did not finish")

            #expect(
                pins.store.pin(for: hostID) == macIdentity.publicKeyBytes,
                "the key written at pairing time is not the key the Mac presented"
            )
            #expect(session.serverKey == macIdentity.publicKeyBytes)
        }
    }

    /// **What it covers is the half of a session that can go without the session going with it.** On
    /// a direct connection the picture travels a socket of its own, and for a long time nothing
    /// re-dialled it: `openVideoIfNeeded()` had one caller, `becomeReady()`, which runs once, so the
    /// first drop was also the last frame. The control channel stayed healthy throughout, which is
    /// what made the failure read as "paused" rather than as "disconnected", and left the phone
    /// showing a frozen picture it could still tap on.
    @Suite("Reconnecting the video socket")
    struct VideoReconnect {
        private func withLiveVideo(
            _ body: (ScriptedMac, ClientSession, SessionLog, MacLink) async throws -> Void
        ) async throws {
            let pins = TestPins()
            defer { pins.destroy() }

            try await withTestEnds { client, macIdentity in
                let hostID = "paired-mac"
                #expect(
                    pins.store.record(hostID: hostID, publicKey: macIdentity.publicKeyBytes),
                    "the pin could not be stored"
                )

                let mac = try ScriptedMac(identity: macIdentity)
                await mac.start()
                defer { mac.stop() }

                let log = SessionLog()
                let session = ClientSession(
                    identity: client,
                    clientID: "phone-1",
                    clientName: "Test iPhone",
                    pins: pins.store,
                    onEvent: { log.record($0) }
                )
                defer { session.disconnect() }

                await session.connect(to: .address(host: "127.0.0.1", port: mac.port), timeout: 10)
                let control = try #require(await mac.nextConnection(), "the client never connected")
                _ = try await greet(control, serverID: hostID, alreadyPaired: true)
                let ready = await log.wait { $0.isReady }
                #expect(ready, "the session did not get past the pin check")

                let video = try #require(
                    await mac.nextConnection(),
                    "the session became ready and never opened a video connection"
                )
                let role = try await video.expect(.connectionRole)
                #expect(role.payload == Data([ConnectionRole.video.rawValue]))

                try await body(mac, session, log, video)
            }
        }

        @Test func aDroppedVideoSocketIsDialledAgain() async throws {
            try await withLiveVideo { mac, _, log, video in
                video.hangUp()

                let replacement = try #require(
                    await mac.nextConnection(within: 5),
                    "the video socket was dropped and never dialled again"
                )
                let replacementRole = try await replacement.expect(.connectionRole)
                #expect(
                    replacementRole.payload == Data([ConnectionRole.video.rawValue]),
                    "the client dialled again and asked for the wrong connection role"
                )

                let reopened = await log.wait {
                    $0.notes.filter { $0.hasPrefix("Video channel open") }.count == 2
                }
                #expect(reopened, "the session never reported the channel opening again: \(log.notes)")
            }
        }

        /// **The half of the rule that keeps the pause meaningful.** A video socket is what makes the
        /// Mac capture, so a client that has asked for no picture and then loses its socket must not
        /// dial another one: the Mac would start capturing again for a phone that told it to stop,
        /// which is the whole of what the pause is for.
        @Test func aPausedSessionDoesNotDialForAPictureItRefused() async throws {
            try await withLiveVideo { mac, session, _, video in
                session.send(.setVideoEnabled(false))
                video.hangUp()

                let dialled = await mac.nextConnection(within: 2)
                #expect(
                    dialled == nil,
                    "the client dialled again for a picture it had just asked not to be sent"
                )
            }
        }

        @Test func askingForThePictureAgainOpensASocket() async throws {
            try await withLiveVideo { mac, session, _, video in
                session.send(.setVideoEnabled(false))
                video.hangUp()
                #expect(await mac.nextConnection(within: 2) == nil)

                session.send(.setVideoEnabled(true))
                let reopened = try #require(
                    await mac.nextConnection(within: 5),
                    "the picture was asked for again and no socket was opened for it"
                )
                let role = try await reopened.expect(.connectionRole)
                #expect(role.payload == Data([ConnectionRole.video.rawValue]))
            }
        }
    }

}
