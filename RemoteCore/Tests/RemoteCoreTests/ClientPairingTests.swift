import CryptoKit
import Foundation
import Network
import Security
import Testing

@testable import RemoteCore

/// A flag two threads can share, for telling a callback apart from a race.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// A test that could not be set up at all, as opposed to one whose subject behaved wrongly.
///
/// Thrown from the helpers below rather than recorded as an expectation, because a test that could
/// not open a listener has nothing to say about the client, and the assertions that follow would be
/// assertions about a session that never ran.
private struct TestSetupError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Whether this machine can hold a keychain key at all, which every test here needs and a CI
/// runner may not have.
///
/// Asked by trying rather than by inspecting: there is no API that answers "is there a usable
/// Keychain here", and the probe is the same call the tests themselves make, so a machine that
/// fails it is a machine where all of them would fail for a reason that has nothing to do with the
/// pin. The probe's key carries a tag of its own and is destroyed immediately, so the check neither
/// reads nor mints the identity the app runs on.
private let keychainIsUsable: Bool = {
    let tag = Data("pl.dmq.maccast.tests.keychain-probe.\(UUID().uuidString)".utf8)
    defer { try? SelfSignedIdentity.destroy(role: .client, keyTag: tag) }
    let identity = try? SelfSignedIdentity.loadOrCreate(
        role: .client,
        commonName: "Keychain probe",
        keyTag: tag
    )
    return identity != nil
}()

/// Runs `body` with an identity of its own, under a tag nothing else uses, and destroys it after.
///
/// **The tag is the whole point.** `loadOrCreate` defaults to a fixed tag belonging to the real
/// app, so a test that let it default would load the developer's own key and the teardown here
/// would then delete it. A fresh tag per identity keeps the two apart in both directions, which is
/// a mistake this project has already made once from a probe, in the other direction.
private func withIdentity<T>(
    role: SelfSignedIdentity.Role,
    commonName: String,
    _ body: (SelfSignedIdentity) async throws -> T
) async throws -> T {
    let tag = Data("pl.dmq.maccast.tests.identity.\(UUID().uuidString)".utf8)
    let identity = try SelfSignedIdentity.loadOrCreate(role: role, commonName: commonName, keyTag: tag)
    defer { try? SelfSignedIdentity.destroy(role: role, keyTag: tag) }
    return try await body(identity)
}

/// Both ends of a test's handshake: this device, and the Mac it is deciding about.
private func withTestEnds<T>(
    _ body: (_ client: SelfSignedIdentity, _ mac: SelfSignedIdentity) async throws -> T
) async throws -> T {
    try await withIdentity(role: .client, commonName: "Test iPhone") { client in
        try await withIdentity(role: .server, commonName: "Scripted Mac") { mac in
            try await body(client, mac)
        }
    }
}

/// A pin store of this test's own.
///
/// The store the app uses is the Keychain and `ClientPinStore` has no injectable backing, so a test
/// that wants to decide what is pinned has to take one of its own. The account is fresh per test so
/// that two tests running at once cannot see each other's pins, and teardown deletes the item
/// rather than leaving behind the empty one `removeAll()` writes: a test run should not add to the
/// machine's Keychain, not even something with nothing in it.
private struct TestPins {
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

/// Everything the session emitted, so a test can wait for the event it is about rather than sleep
/// for long enough and hope.
///
/// Polled rather than signalled, and that is deliberate: the session reports from whichever queue
/// the network handed it, and what a test can honestly assert is that an event arrives, not that it
/// arrives before the next line runs.
private final class SessionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ClientSession.Event] = []

    func record(_ event: ClientSession.Event) { lock.withLock { events.append(event) } }

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

    /// The sentence the session failed with, or `nil` while it has not failed.
    ///
    /// The last one rather than the first: a session that fails twice says the same thing twice,
    /// and reading the newest is what a caller that just waited for a failure wants.
    var failure: String? {
        for phase in phases.reversed() {
            if case .failed(let message) = phase { return message }
        }
        return nil
    }

    var isReady: Bool { phases.contains(.ready) }

    /// The six digits the session is asking the user to compare, or `nil` while it is not asking.
    var confirmingCode: String? {
        for phase in phases.reversed() {
            if case .confirming(let code) = phase { return code }
        }
        return nil
    }

    /// Polls until the condition holds, or until the deadline passes, and says which.
    func wait(within seconds: TimeInterval = 10, until condition: (SessionLog) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition(self) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition(self)
    }
}

/// A Mac on loopback, scripted rather than running.
///
/// The decision under test is a decision about *which Mac answered*, so there is no way to make it
/// without a Mac to answer with: a stub below this level would replace the certificate and the
/// hello, and those are the evidence the decision is made from. So what this is instead is the
/// smallest Mac the client will talk to: a TLS listener with a key of its own, and the frames
/// `HostSession` answers with, in the order that file sends them.
private final class ScriptedMac: @unchecked Sendable {
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

    /// The next connection the client opens, started and ready to carry bytes.
    ///
    /// A session that reaches ready opens a second socket for video, so this takes them in the
    /// order they arrive and the callers that only care about the control channel take the first.
    /// Bounded like the reads below: a client that never connects has to fail the test with a
    /// sentence rather than hang it.
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

/// One accepted connection, read as frames.
///
/// Frames are collected into a queue and polled rather than handed back through a continuation.
/// A scripted Mac reads two or three frames in its whole life, and polling cannot lose one to a
/// race between the connection's queue and the test's.
private final class MacLink: @unchecked Sendable {
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

    /// Waits until the connection can carry bytes, or until it has ended.
    ///
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

    /// The host's hello, which is the frame the pin decision turns on.
    func sendHello(serverID: String, alreadyPaired: Bool) {
        send(.serverHello, ServerHello(
            serverID: serverID,
            hostName: "Scripted Mac",
            protocolVersion: ProtocolInfo.version,
            alreadyPaired: alreadyPaired
        ))
    }

    // MARK: - Receiving

    /// The next frame the client sent, or `nil` if none arrives before the deadline.
    ///
    /// Bounded on purpose, like the reads in the relay splice tests: a frame that never arrives has
    /// to come back as nothing rather than as a test that hangs, or the assertion that fails says
    /// only that something did not happen.
    func next(within seconds: TimeInterval = 10) async -> Frame? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let frame = dequeue() { return frame }
            if hasEnded() { return nil }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return dequeue()
    }

    /// The next frame, with its kind checked.
    ///
    /// Checked rather than skipped: what a handshake *is* is the order of these frames, and a
    /// helper that discarded anything unexpected would pass against a client that sent them in the
    /// wrong order. It throws rather than recording, so a test stops at the first frame that was
    /// not what the protocol says instead of piling further assertions onto a stream that has
    /// already gone wrong.
    func expect(_ kind: MessageKind, within seconds: TimeInterval = 10) async throws -> Frame {
        guard let frame = await next(within: seconds) else {
            // What the link did is part of the sentence: a connection that ended during the TLS
            // handshake and one the test read too slowly look identical from an assertion that
            // only knows no frame arrived.
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
            // The client wrote bytes this end cannot frame, which is a fault in the test's own
            // script rather than a network condition. Ending the link makes the next read return
            // nothing instead of waiting on a decoder that can never advance again.
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

/// The opening every connection makes, and the Mac's answer to it.
///
/// Returns the client's hello, which is where the ID the pin is keyed by is claimed, so a test can
/// check that the client is asking about the Mac it thinks it is.
@discardableResult
private func greet(_ link: MacLink, serverID: String, alreadyPaired: Bool) async throws -> ClientHello {
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

/// The sentence the session's own phase holds, or `nil` while it has not failed.
///
/// **Both surfaces, not just the event.** A failure during connect reaches the session twice: once
/// from the catch around the connect call, and once from the connection's own close. The first of
/// those to arrive is emitted as an event and the second overwrites `phase` in silence, so which
/// one a reader sees depends on which arrived first. A test that read only the events would be
/// reading the winner of a race, and the shipped bug lived exactly in that gap: the old connect
/// path replaced the transport's sentence with an identity one, and whether anybody saw it came
/// down to the order two fault reporters got there in.
private func failurePhase(_ session: ClientSession) -> String? {
    if case .failed(let message) = session.phase { return message }
    return nil
}

/// The endpoint for a port on this machine, which is the only host these tests dial.
private func loopback(_ port: UInt16) throws -> NWEndpoint {
    guard let port = NWEndpoint.Port(rawValue: port) else {
        throw TestSetupError("\(port) is not a usable TCP port")
    }
    return .hostPort(host: "127.0.0.1", port: port)
}

/// A loopback port with nothing listening on it.
///
/// Taken by a listener and then given back rather than guessed at: a port that happened to be free
/// on the machine this was written on proves nothing about the machine running it, and a test that
/// fails because something else took 9999 is a test nobody trusts.
///
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

/// The sentences a failure that came from the network can produce.
///
/// Built from `NetworkFailureText` rather than written out, because the assertion it serves is that
/// the message came from that table: a test that listed the words itself would keep passing after
/// the table changed, which is the wrong thing for a test about the table's reach to do.
private let transportSentences: Set<String> = [
    NetworkFailureText.describe(POSIXErrorCode.ECONNREFUSED),
    NetworkFailureText.describe(POSIXErrorCode.ECONNRESET),
    NetworkFailureText.describe(POSIXErrorCode.ETIMEDOUT),
    NetworkFailureText.describe(POSIXErrorCode.EHOSTUNREACH),
    NetworkFailureText.describe(POSIXErrorCode.ENETUNREACH),
    NetworkFailureText.describe(POSIXErrorCode.EHOSTDOWN),
    NetworkFailureText.describe(POSIXErrorCode.EPIPE),
    NetworkFailureText.describe(POSIXErrorCode.ENETDOWN),
    // The transport's own sentences, for the failures that are not a POSIX code at all: the
    // connect deadline, which carries the timeout that was asked for, and anything from TLS that
    // this build cannot name. The 5 is the timeout the test above dials with.
    ClientConnection.Failure.timedOut(5).errorDescription ?? "",
    ClientConnection.Failure.hostClosed.errorDescription ?? "",
    "The connection to the Mac failed.",
]

/// Whether the client accepts the Mac it is talking to.
///
/// **What this covers, and what nothing did.** `ClientSession` decides whether the Mac that
/// answered is the one this device paired with, and that decision is the pin: the phone stores the
/// Mac's public key when it pairs, and refuses a connection that presents another one. Nothing
/// tested the decision, and a shipped bug came out of that gap. The connect path announced an
/// identity change for *any* failure to a paired Mac, so a Mac that was merely asleep produced
/// "its key does not match the key this iPhone pinned for it", with the advice to forget the Mac
/// and pair again. The wording was covered by `NetworkFailureTextTests`; whether the session ever
/// reached for that wording was not.
///
/// What these tests drive is a real `ClientSession` against a scripted Mac over loopback, so the
/// key it decides about arrives in a TLS certificate rather than as a fixture handed to it.
///
/// Serialized because each one mints two P-256 keys in the Keychain, and the Keychain does not mint
/// several at once reliably: running three of these in parallel failed about one test in three with
/// `errSecItemNotFound` out of `SecKeyCreateRandomKey`, on a machine where the app itself has never
/// had trouble creating the one key it needs. Sequential runs do not, which is worth the two seconds.
@Suite("The client's pairing decision", .serialized, .timeLimit(.minutes(1)), .enabled(if: keychainIsUsable))
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
    /// must not be reported as a Mac whose identity changed.
    ///
    /// The Mac is dialled through a target that carries a pin, which is what a paired Mac is. That
    /// matters: the old connect path asked whether a pin was *in force* (`pinned != nil`), decided
    /// on that basis that the Mac's identity was the problem, and told the user to break a working
    /// pairing over a sleeping Mac. A test that dialled an address would have had no pin in force
    /// and would have passed against the bug.
    ///
    /// What comes back now is the transport's own sentence, and that is what is asserted: not
    /// merely that the identity sentence is absent, but that the message is one the network table
    /// produces.
    @Test func aMacThatIsNotThereIsNotAnIdentityFailure() async throws {
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

            // There is nothing to wait for. A connect that fails does so before it returns, and
            // the session fails and reports the sentence in the same call, which is the contract
            // its own documentation states.
            let emitted = try #require(log.failure, "the session never failed")
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

            // And the two agree. They are the same failure reported from two places, so a user who
            // reads the notification and a user who reads the screen must not be told different
            // things about the same second.
            #expect(emitted == reported)

            // And the pin is exactly as it was. A failed attempt must not disturb the store, or the
            // next connection would be judged against something nobody approved.
            #expect(pins.store.pin(for: hostID) == pinnedKey)
        }
    }

    /// **The decision itself, in the direction that refuses.** A Mac whose certificate key is not
    /// the pinned one is a pin mismatch, in the words that carry the way out.
    ///
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
            // The key this device pinned, which is not the one the Mac is about to present. A key
            // of the right shape, so the comparison fails for the only reason it can: the bytes.
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
            // Held as well as said. A refusal that reached the event stream and left `phase`
            // saying something else would put two different sentences in front of the user.
            #expect(failurePhase(session) == message)
            #expect(message.contains("not the Mac you paired with"))
            #expect(message.contains("pinned"))
            #expect(message.contains("pair again"))

            // The pin that was compared is still the one on file, and it is the one this test
            // wrote: a refusal must not quietly rewrite the store to whatever it just met.
            #expect(pins.store.pin(for: hostID) == pinnedKey)

            // And the key it compared against is the one from the certificate. Without this the
            // test could pass against a session that compared the wrong two values, or that failed
            // for a reason of its own on the way to the pin.
            #expect(session.serverKey == macIdentity.publicKeyBytes)
        }
    }

    /// The same decision in the direction that lets a Mac through.
    ///
    /// Asserted by the note the session emits when a pin is accepted, which is the only thing that
    /// separates "the check ran and passed" from "the check never ran". The failure case above
    /// covers the other outcome, and a session that skipped the check entirely would look like
    /// this one from the outside.
    @Test func aMacWhoseKeyMatchesThePinIsLetThrough() async throws {
        let pins = TestPins()
        defer { pins.destroy() }

        try await withTestEnds { client, macIdentity in
            let hostID = "paired-mac"
            // Pinned to the Mac's real key, which is the state a completed pairing leaves behind.
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

            // The key the client read out of this Mac's certificate is the same value this test
            // pinned, which is what the pin's whole meaning rests on: the bytes stored at pairing
            // time and the bytes a later connection presents have to be the same kind of thing.
            #expect(session.serverKey == macIdentity.publicKeyBytes)
            #expect(pins.store.pin(for: hostID) == macIdentity.publicKeyBytes)
        }
    }

    /// **Where the pin comes from.** A Mac this device has never met is paired with, and what the
    /// session writes to the store afterwards is the key that Mac presented in its certificate.
    ///
    /// This is the assertion the two tests above cannot make on their own: they start from a pin
    /// the test wrote, so they prove the check reads the store, and this one proves what the store
    /// is filled with. Between them the decision is covered from both ends of its life, and the
    /// value in the middle is the Mac's real key rather than a fixture.
    ///
    /// It also covers the half of the handshake that has nothing to do with the pin and everything
    /// to do with what the pin is for: the six digits both screens show. They are derived from a
    /// transcript of everything the two ends exchanged, and if the two built it differently the
    /// digits would differ, the user would say so, and a working Mac would look like an impostor.
    /// The scripted Mac computes them the way `HostSession` does, so a change to one side's
    /// transcript that the other did not make fails here.
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

            // The Mac's half of the commitment exchange, in `HostSession`'s order: its commitment
            // goes out before the client's is read, and its reveal only after that arrives. Sent
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

            // The user's half: two screens showing six digits. The two ends have to have built the
            // same transcript out of the same exchange, and this is where that stops being an
            // assumption about the code and becomes something a person would have noticed.
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

            // **What the pin store holds afterwards, which is the thing every later connection is
            // judged against.** Not a key the test handed over: the one this Mac presented in the
            // certificate the client received, read out of it by the client itself.
            #expect(
                pins.store.pin(for: hostID) == macIdentity.publicKeyBytes,
                "the key written at pairing time is not the key the Mac presented"
            )
            #expect(session.serverKey == macIdentity.publicKeyBytes)
        }
    }
}
