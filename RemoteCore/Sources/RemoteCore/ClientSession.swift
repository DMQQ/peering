// CryptoKit is the system framework on Apple platforms; the open-source swift-crypto
// module is named `Crypto`. Same API either way, so the package stays dependency-free
// on Apple platforms without giving up portability.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Network
import Security
import os

private let sessionLog = Logger(subsystem: "pl.dmq.peering", category: "session")

/// The client half of the MacCast protocol: connect, authenticate, and stay usable.
///
/// This is the client's counterpart to the host's `HostSession`, and it is deliberately the
/// same shape — a single state machine driven by frames from one connection, so the ordering
/// guarantees the handshake depends on are enforced in exactly one place.
///
/// Two sockets, always. ``control`` carries the handshake, commands, and the catalog;
/// ``video`` carries nothing but encoded pictures. The split is not an optimisation: a
/// single stream would put a 200 KB keyframe in front of the next mouse move, and cursor
/// latency is the thing a user actually feels.
public final class ClientSession: @unchecked Sendable {
    /// Where the session is in its life. Coarse on purpose — the UI renders this directly,
    /// so a finer state machine would just be a longer switch in the view.
    public enum Phase: Sendable, Equatable {
        case idle
        case connecting
        case handshaking
        /// Waiting for the human to compare six digits with the Mac's screen.
        case confirming(code: String)
        case ready
        case failed(String)
        case disconnected

        /// Whether a session is up, or on its way up, at this phase.
        ///
        /// A property of the state machine rather than of any one caller, and it lives here
        /// because three of them were asking it: the model, the notification policy, and the
        /// Live Activity. Three copies of a list of phases is three chances to update two of
        /// them when a state is added.
        public var holdsSession: Bool {
            switch self {
            case .connecting, .handshaking, .confirming, .ready: return true
            case .idle, .failed, .disconnected: return false
            }
        }
    }

    /// What the session tells its owner. Everything is a value, so the UI can apply these
    /// on whatever actor it likes.
    public enum Event: Sendable {
        case phase(Phase)
        case host(ServerHello)
        case catalog(CaptureCatalog)
        case video(VideoEvent)
        /// Round-trip time of a control ping, in milliseconds. The control channel is the
        /// one whose latency the user feels, so this is the number worth showing.
        case latency(milliseconds: Double)
        /// Diagnostics worth surfacing without failing: a pin that was accepted, a video
        /// channel that connected but has not produced a stream yet.
        case note(String)
    }

    public enum VideoEvent: Sendable {
        case connecting
        case config(VideoStreamConfig)
        case frame(EncodedVideoFrame)
        case ended(String)
    }

    /// How to reach a Mac. Both paths end in the same TLS + pairing handshake; they differ
    /// only in whether an address had to be resolved first.
    public enum Target: Sendable {
        /// Found over Bonjour. Carries the interface it was discovered on, which is the path
        /// that actually works on a Mac with several.
        case discovered(DiscoveredHost)
        /// A literal address. What the simulator needs, since Bonjour there is unreliable —
        /// and the honest fallback for a network that blocks multicast.
        case address(host: String, port: UInt16)
        /// A previously paired Mac reached through `peeringd` by its stable device ID.
        case relay(hostID: String, name: String)

        public var displayName: String {
            switch self {
            case .discovered(let host): return host.name
            case .address(let host, let port): return "\(host):\(port)"
            case .relay(_, let name): return name
            }
        }
    }

    public enum Failure: LocalizedError, Sendable {
        case busy
        case notReady
        case protocolMismatch(client: UInt16, host: UInt16)
        case commitmentMismatch
        case noServerKey
        case pinMismatch(hostID: String)
        case unexpected(MessageKind, expected: String)
        case identity(String)

        public var errorDescription: String? {
            switch self {
            case .busy:
                return "This session is already connecting or connected."
            case .notReady:
                return "The session is not connected."
            case .protocolMismatch(let client, let host):
                return "This Mac speaks protocol v\(host) and this app speaks v\(client). Update whichever is older."
            case .commitmentMismatch:
                // Reached only when a peer changed its contribution after seeing ours, which
                // no honest implementation does.
                return "The Mac's pairing reveal did not match its commitment."
            case .noServerKey:
                return "The Mac's certificate did not expose a public key, so it cannot be pinned."
            case .pinMismatch(let hostID):
                return "Something at this address is not the Mac you paired with (\(hostID)). Its key does not match the stored pin."
            case .unexpected(let kind, let expected):
                return "Expected \(expected) from the Mac, got \(kind)."
            case .identity(let detail):
                return "This device's identity could not be loaded: \(detail)"
            }
        }
    }

    // MARK: - Configuration held for the session's life

    private let identity: SelfSignedIdentity
    private let clientID: String
    private let clientName: String
    private let pins: ClientPinStore
    private let onEvent: @Sendable (Event) -> Void

    /// The command queue, created once and reused across reconnects so a gesture in flight
    /// is not stranded by a reconnect. Its sink reads the current control connection under
    /// the lock, so a queued command can never be delivered to a dead socket.
    private let coalescer: CommandCoalescer

    // MARK: - State, all under `lock`

    private let lock = NSLock()
    private var _phase: Phase = .idle
    private var control: ClientConnection?
    private var video: ClientConnection?
    private var relayProxy: RelayControlProxy?
    private var usesRelayedSingleStream = false
    private var _serverHello: ServerHello?
    private var _catalog: CaptureCatalog?
    private var _serverKey: Data?
    private var state: HandshakeState = .idle
    private var pingTask: Task<Void, Never>?
    private var pingSentAt: DispatchTime?

    private var ephemeral: P256.KeyAgreement.PrivateKey?
    private var nonce: Data?
    private var remoteCommitment: Data?

    /// Where the handshake has got to. Separate from ``Phase`` because the UI does not need
    /// to distinguish "waiting for the server's commit" from "waiting for its reveal", but
    /// the state machine very much does.
    private enum HandshakeState {
        case idle
        case awaitingServerHello
        case awaitingServerCommit
        case awaitingServerReveal
        case awaitingUserConfirmation
        case awaitingPairResult
        case ready
        case failed
    }

    public init(
        identity: SelfSignedIdentity,
        clientID: String,
        clientName: String,
        pins: ClientPinStore = .standard,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.identity = identity
        self.clientID = clientID
        self.clientName = clientName
        self.pins = pins
        self.onEvent = onEvent

        // `self` cannot be captured before every stored property is initialised, so the
        // coalescer is built with a closure that reads the connection through a box filled
        // in immediately afterwards. The alternative — making the whole class lazy — would
        // put a lock in the path of every cursor sample.
        let box = ConnectionBox()
        coalescer = CommandCoalescer(sink: { command in box.send(command) })
        box.attach(self)
    }

    deinit {
        pingTask?.cancel()
        coalescer.stop()
    }

    /// Holds the session weakly so the coalescer's sink can reach the live control
    /// connection without creating a retain cycle through the timer.
    private final class ConnectionBox: @unchecked Sendable {
        private let lock = NSLock()
        private weak var session: ClientSession?

        func attach(_ session: ClientSession) { lock.withLock { self.session = session } }

        func send(_ command: RemoteCommand) {
            lock.withLock { session }?.sendNow(command)
        }
    }

    // MARK: - Observable state

    public var phase: Phase { lock.withLock { _phase } }
    public var serverHello: ServerHello? { lock.withLock { _serverHello } }
    public var catalog: CaptureCatalog? { lock.withLock { _catalog } }
    /// The Mac's identity key, from its TLS certificate.
    public var serverKey: Data? { lock.withLock { _serverKey } }
    public var isReady: Bool { lock.withLock { state == .ready } }

    // MARK: - Connect

    /// Runs the whole client side of the handshake and returns once the outcome is known:
    /// either the session is ready, or it has failed and the reason has been emitted.
    ///
    /// Returning rather than throwing is deliberate. Every failure already reaches the UI as
    /// a ``Phase/failed(_:)`` event, and a caller that also had to catch would have two
    /// places to render the same message — which is how one of them ends up stale.
    public func connect(to target: Target, timeout: TimeInterval = 10) async {
        guard beginConnecting() else {
            emit(.phase(.failed(Failure.busy.errorDescription ?? "busy")))
            return
        }
        emit(.phase(.connecting))

        let pinned: Data? = {
            if case .discovered(let host) = target { return pins.pin(for: host.id) }
            if case .relay(let hostID, _) = target { return pins.pin(for: hostID) }
            // A literal address says nothing about *which* Mac is at it, so there is no pin
            // to insist on before the handshake. The post-handshake check below covers it.
            return nil
        }()

        let connection = ClientConnection(label: "pl.dmq.peering.client.control")
        connection.onFrame = { [weak self] frame in self?.handle(frame) }
        connection.onClose = { [weak self] failure in self?.controlClosed(failure) }
        lock.withLock { control = connection }

        do {
            switch target {
            case .discovered(let host):
                try await connection.connect(
                    to: host.endpoint,
                    identity: identity,
                    pinnedServerKey: pinned,
                    timeout: timeout
                )
            case .address(let host, let port):
                try await connection.connect(
                    host: host,
                    port: port,
                    identity: identity,
                    pinnedServerKey: nil,
                    timeout: timeout
                )
            case .relay(let hostID, _):
                guard let pin = pins.pin(for: hostID) else {
                    throw Failure.pinMismatch(hostID: hostID)
                }
                let allocation = try await RelaySignallingConnection.requestSession(
                    at: ProtocolInfo.relaySignallingURL,
                    hostID: hostID,
                    clientID: clientID
                )
                let proxy = RelayControlProxy(session: allocation)
                let endpoint = try await proxy.start()
                lock.withLock {
                    relayProxy = proxy
                    usesRelayedSingleStream = true
                }
                try await connection.connect(
                    to: endpoint,
                    identity: identity,
                    pinnedServerKey: pin,
                    timeout: timeout
                )
            }
        } catch {
            let isRelaySetupFailure = error is RelaySignallingError || error is RelayTunnelError
            let message = (pinned != nil && !isRelaySetupFailure)
                // A pin was in force and TLS refused, which is the one failure worth naming
                // precisely: it is either an impostor or a Mac that was reset.
                ? "The Mac at \(target.displayName) did not present the key this device has pinned for it. If it was reset, forget it here and pair again."
                : (error as? LocalizedError)?.errorDescription ?? "\(error)"
            fail(message)
            return
        }

        lock.withLock { _serverKey = connection.observedServerKey }
        emit(.note("Connected over \(connection.negotiatedTLSVersion)"))

        // 1. Declare the role. One listener serves both channels, and this is what tells the
        //    Mac which one it just accepted.
        connection.send(Frame(
            kind: .connectionRole,
            payload: Data([ConnectionRole.control.rawValue])
        ))

        // 2. Say who we are. `wantsPairing` is advisory — the Mac decides, because only the
        //    Mac knows its own pin store.
        let hostID: String? = {
            if case .discovered(let host) = target { return host.id }
            if case .relay(let hostID, _) = target { return hostID }
            return nil
        }()
        let knowsHost = hostID.map { pins.pin(for: $0) != nil } ?? false
        connection.send(.clientHello, ClientHello(
            clientID: clientID,
            clientName: clientName,
            protocolVersion: ProtocolInfo.version,
            wantsPairing: !knowsHost
        ))

        lock.withLock { state = .awaitingServerHello }
        emit(.phase(.handshaking))
        coalescer.start()
    }

    /// Claims the session for one connect attempt. Returns `false` if it is already in use,
    /// so a double tap on "Connect" cannot leave two handshakes racing on one object.
    private func beginConnecting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .idle, .failed:
            state = .idle
            _phase = .connecting
            return true
        default:
            return false
        }
    }

    // MARK: - Frame routing

    private func handle(_ frame: Frame) {
        lock.lock()
        let current = state
        lock.unlock()

        switch current {
        case .awaitingServerHello: handleServerHello(frame)
        case .awaitingServerCommit: handleServerCommit(frame)
        case .awaitingServerReveal: handleServerReveal(frame)
        case .awaitingUserConfirmation:
            // Nothing is expected here. A frame at this point would mean the Mac raced ahead
            // of a decision the user has not made yet, so it is ignored rather than acted on.
            sessionLog.notice("ignoring \(String(describing: frame.kind), privacy: .public) while awaiting the user's pairing decision")
        case .awaitingPairResult: handlePairResult(frame)
        case .ready: handleReady(frame)
        case .idle, .failed:
            break
        }
    }

    private func handleServerHello(_ frame: Frame) {
        guard frame.kind == .serverHello else {
            fail(Failure.unexpected(frame.kind, expected: "serverHello").errorDescription ?? "")
            return
        }
        guard let hello = try? MessageCodec.decode(ServerHello.self, from: frame.payload) else {
            fail("The Mac's hello could not be read.")
            return
        }
        guard hello.protocolVersion == ProtocolInfo.version else {
            fail(Failure.protocolMismatch(client: ProtocolInfo.version, host: hello.protocolVersion).errorDescription ?? "")
            return
        }
        guard let serverKey = lock.withLock({ _serverKey }) else {
            fail(Failure.noServerKey.errorDescription ?? "")
            return
        }

        lock.withLock { _serverHello = hello }
        emit(.host(hello))

        // The pin is checked here, after the handshake, because until `serverHello` arrived
        // there was no way to know *which* Mac this is — and a pin is only meaningful next to
        // the identity it belongs to. Nothing has been sent yet that an impostor could use:
        // the only traffic so far is a role byte, a hello carrying no secret, and our client
        // certificate, which is public.
        if let stored = pins.pin(for: hello.serverID) {
            guard SPKI.matches(stored, serverKey) else {
                fail(Failure.pinMismatch(hostID: hello.serverID).errorDescription ?? "")
                return
            }
            emit(.note("The Mac's key matches the pin stored for it."))
        } else if hello.alreadyPaired {
            // Reached only when this device lost its pin store while the Mac kept its half.
            // It is not a way in for an attacker: the Mac only answers `alreadyPaired` to a
            // client whose *certificate* it recognises, and our identity key is stored
            // `…ThisDeviceOnly`, so it cannot be carried here by a backup restore. The
            // alternative — refusing — would strand the user with an app that can never
            // connect until they unpair on the Mac, for a state that is already safe.
            emit(.note("The Mac already knows this device. Pairing was skipped."))
        }

        if hello.alreadyPaired {
            becomeReady()
        } else {
            beginPairing()
        }
    }

    // MARK: - Pairing

    /// Opens the commitment exchange. See ``PairingSAS`` for why the commitment exists:
    /// without it an active attacker grinds a keypair until its own contribution reproduces
    /// the digits the Mac is about to display.
    private func beginPairing() {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        guard let nonce = try? Self.randomBytes(32) else {
            fail("This device could not obtain secure random bytes.")
            return
        }
        lock.withLock {
            self.ephemeral = ephemeral
            self.nonce = nonce
            state = .awaitingServerCommit
        }

        let commitment = PairingSAS.commitment(
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            nonce: nonce
        )
        connection()?.send(.pairCommit, PairingCommit(commitment: commitment))
    }

    private func handleServerCommit(_ frame: Frame) {
        guard frame.kind == .pairCommit else {
            fail(Failure.unexpected(frame.kind, expected: "pairCommit").errorDescription ?? "")
            return
        }
        guard let commit = try? MessageCodec.decode(PairingCommit.self, from: frame.payload),
              let ephemeral = lock.withLock({ self.ephemeral }),
              let nonce = lock.withLock({ self.nonce })
        else {
            fail("The Mac's pairing commitment could not be read.")
            return
        }

        lock.withLock {
            remoteCommitment = commit.commitment
            state = .awaitingServerReveal
        }

        // Reveal only now, having seen the Mac's commitment. Sending ours first would let it
        // pick its own contribution with ours already known.
        connection()?.send(.pairReveal, PairingReveal(
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            nonce: nonce
        ))
    }

    private func handleServerReveal(_ frame: Frame) {
        guard frame.kind == .pairReveal else {
            fail(Failure.unexpected(frame.kind, expected: "pairReveal").errorDescription ?? "")
            return
        }
        guard let reveal = try? MessageCodec.decode(PairingReveal.self, from: frame.payload) else {
            fail("The Mac's pairing reveal could not be read.")
            return
        }

        // Read as separate locals rather than one destructured tuple: a five-element tuple of
        // optionals is the kind of expression the type checker gives up on, and the failure
        // ("unable to type-check in reasonable time") points at nothing useful.
        lock.lock()
        let ephemeral = self.ephemeral
        let nonce = self.nonce
        let commitment = self.remoteCommitment
        let hello = self._serverHello
        let serverKey = self._serverKey
        lock.unlock()

        guard let ephemeral, let nonce, let commitment, let hello, let serverKey else {
            fail("The pairing exchange lost its state.")
            return
        }

        guard PairingSAS.verify(
            commitment: commitment,
            ephemeralPublicKey: reveal.ephemeralPublicKey,
            nonce: reveal.nonce
        ) else {
            fail(Failure.commitmentMismatch.errorDescription ?? "")
            return
        }

        // The transcript binds everything both sides exchanged, in a fixed order, with the
        // Mac's identity key taken from the certificate we actually received — never from an
        // application-layer field, which a man in the middle would simply rewrite.
        let transcript = PairingTranscript(
            protocolVersion: ProtocolInfo.version,
            clientID: clientID,
            serverID: hello.serverID,
            clientEphemeralPublicKey: ephemeral.publicKey.x963Representation,
            serverEphemeralPublicKey: reveal.ephemeralPublicKey,
            clientNonce: nonce,
            serverNonce: reveal.nonce,
            serverIdentityPublicKey: serverKey
        )

        lock.withLock { state = .awaitingUserConfirmation }
        let code = PairingSAS.code(for: transcript)
        emit(.phase(.confirming(code: code)))
    }

    /// The user's verdict on the six digits. The Mac shows the same code, and comparing them
    /// is what authorises this device — there is no certificate authority behind any of this.
    public func confirmPairing(accepted: Bool) {
        lock.lock()
        let canConfirm = state == .awaitingUserConfirmation
        if accepted, canConfirm { state = .awaitingPairResult }
        lock.unlock()

        guard canConfirm else { return }
        connection()?.send(.pairConfirm, PairConfirm(accepted: accepted))

        guard accepted else {
            emit(.note("Pairing declined."))
            disconnect()
            return
        }
    }

    private func handlePairResult(_ frame: Frame) {
        guard frame.kind == .pairResult else {
            fail(Failure.unexpected(frame.kind, expected: "pairResult").errorDescription ?? "")
            return
        }
        guard let result = try? MessageCodec.decode(PairResult.self, from: frame.payload) else {
            fail("The Mac's pairing result could not be read.")
            return
        }
        guard result.accepted else {
            fail(result.reason ?? "The Mac refused the pairing.")
            return
        }

        // The pin is only recorded once the Mac has confirmed it stored its half. Recording
        // it earlier would leave this device insisting on a pin the Mac never agreed to, and
        // every later connection would fail with a mismatch that looks like an attack.
        lock.lock()
        let hello = self._serverHello
        let serverKey = self._serverKey
        lock.unlock()

        if let hello, let serverKey, !pins.record(hostID: hello.serverID, publicKey: serverKey) {
            fail("The pairing succeeded but this device could not save it. Check that the Keychain is available.")
            return
        }

        emit(.note("Paired and pinned."))
        becomeReady()
    }

    // MARK: - Ready

    private func becomeReady() {
        lock.withLock { state = .ready }
        emit(.phase(.ready))

        // A video connection is authorized by an *authenticated* control session for the same
        // peer key, so it can only be opened once the handshake above has finished.
        if lock.withLock({ usesRelayedSingleStream }) {
            emit(.video(.connecting))
            emit(.note("Remote session open; video is sharing the encrypted relay stream."))
        } else {
            openVideoIfNeeded()
        }
        startPinging()
    }

    private func handleReady(_ frame: Frame) {
        switch frame.kind {
        case .catalog:
            guard let catalog = try? MessageCodec.decode(CaptureCatalog.self, from: frame.payload) else {
                sessionLog.error("could not decode a capture catalog")
                return
            }
            lock.withLock { _catalog = catalog }
            emit(.catalog(catalog))

        case .pong:
            reportLatency()

        case .error:
            let payload = try? MessageCodec.decode(ErrorPayload.self, from: frame.payload)
            fail(payload?.message ?? "The Mac reported an error.")

        case .videoConfig, .videoFrame:
            handleVideoFrame(frame)

        default:
            sessionLog.notice("ignoring unexpected \(String(describing: frame.kind), privacy: .public) on a ready session")
        }
    }

    /// Sends a command, subject to the coalescing rules in ``CommandCoalescer``.
    ///
    /// This is the only path input takes. Nothing in the UI sends directly, so the rule that
    /// a 120 Hz touch stream becomes a 60 Hz command stream — and that a `mouseUp` is never
    /// dropped even when the queue is saturated — holds in one place instead of in each view.
    public func send(_ command: RemoteCommand) {
        guard isReady else { return }
        coalescer.enqueue(command)
    }

    /// Switches what the Mac is capturing. Sent as an ordinary command so it rides the same
    /// ordered channel as input, and marked critical so it survives a saturated queue.
    public func selectCaptureSource(_ source: CaptureSource) {
        send(.setCaptureSource(source))
    }

    private func sendNow(_ command: RemoteCommand) {
        connection()?.send(command)
    }

    // MARK: - Liveness

    private func startPinging() {
        lock.lock()
        guard pingTask == nil else { lock.unlock(); return }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.lock.withLock { self.pingSentAt = DispatchTime.now() }
                self.connection()?.send(Frame(kind: .ping))
            }
        }
        pingTask = task
        lock.unlock()
    }

    private func reportLatency() {
        guard let sent = lock.withLock({ pingSentAt }) else { return }
        let nanoseconds = DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds
        emit(.latency(milliseconds: Double(nanoseconds) / 1_000_000))
    }

    // MARK: - Video

    /// Opens the second socket. Safe to call repeatedly; only the first call does anything.
    public func openVideoIfNeeded() {
        lock.lock()
        let alreadyOpen = video != nil
        guard !alreadyOpen, state == .ready, let serverKey = _serverKey,
              let hello = _serverHello, let endpoint = control?.remoteEndpoint
        else {
            lock.unlock()
            return
        }
        let connection = ClientConnection(label: "pl.dmq.peering.client.video")
        video = connection
        lock.unlock()

        connection.onFrame = { [weak self] frame in self?.handleVideoFrame(frame) }
        connection.onClose = { [weak self] failure in
            guard let self else { return }
            self.lock.withLock { if self.video === connection { self.video = nil } }
            // A cancellation is our own doing — either the session is over or the socket was
            // replaced — and reporting it would put "video connection ended" on screen after
            // a deliberate disconnect.
            guard failure != .cancelled else { return }
            self.emit(.video(.ended(failure.errorDescription ?? "video connection ended")))
        }

        emit(.video(.connecting))

        Task { [weak self] in
            guard let self else { return }
            do {
                // Now that the Mac's identity is known, the pin is enforced *in* the TLS
                // verify block on this socket too, not merely checked afterwards.
                try await connection.connect(
                    to: endpoint,
                    identity: self.identity,
                    pinnedServerKey: self.pins.pin(for: hello.serverID) ?? serverKey,
                    timeout: 10
                )
            } catch {
                self.emit(.video(.ended(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )))
                return
            }

            connection.send(Frame(
                kind: .connectionRole,
                payload: Data([ConnectionRole.video.rawValue])
            ))
            self.emit(.note("Video channel open; waiting for the Mac to start streaming."))
        }
    }

    private func handleVideoFrame(_ frame: Frame) {
        switch frame.kind {
        case .videoConfig:
            guard let config = try? MessageCodec.decode(VideoStreamConfig.self, from: frame.payload) else {
                sessionLog.error("could not decode a video config")
                return
            }
            emit(.video(.config(config)))

        case .videoFrame:
            do {
                emit(.video(.frame(try EncodedVideoFrame(decoding: frame.payload))))
            } catch {
                // A malformed frame is dropped rather than fatal: one bad picture is worth
                // less than the whole session, and the next keyframe restores the stream.
                sessionLog.error("dropping a malformed video frame: \(String(describing: error), privacy: .public)")
            }

        case .error:
            let payload = try? MessageCodec.decode(ErrorPayload.self, from: frame.payload)
            emit(.video(.ended(payload?.message ?? "the Mac reported an error")))

        default:
            break
        }
    }

    // MARK: - Teardown

    private func controlClosed(_ failure: ClientConnection.Failure) {
        lock.lock()
        let wasFailed = state == .failed
        let deliberate = failure == .cancelled
        lock.unlock()

        if deliberate {
            emit(.phase(.disconnected))
            return
        }
        // The Mac's own explanation arrives as an `.error` frame immediately before the
        // close. Reporting the close as well would replace a sentence the user can act on
        // with "connection reset".
        guard !wasFailed else { return }
        fail(failure.errorDescription ?? "The connection ended.")
    }

    /// Ends the session, deliberately. The pin survives; only the sockets go.
    public func disconnect() {
        lock.lock()
        let control = self.control
        let video = self.video
        let relayProxy = self.relayProxy
        self.control = nil
        self.video = nil
        self.relayProxy = nil
        usesRelayedSingleStream = false
        pingTask?.cancel()
        pingTask = nil
        state = .idle
        _phase = .disconnected
        ephemeral = nil
        nonce = nil
        remoteCommitment = nil
        lock.unlock()

        coalescer.flush()
        video?.cancel()
        control?.cancel()
        relayProxy?.cancel()
        emit(.phase(.disconnected))
    }

    private func fail(_ message: String) {
        lock.lock()
        let alreadyFailed = state == .failed
        state = .failed
        _phase = .failed(message)
        let video = self.video
        let relayProxy = self.relayProxy
        self.video = nil
        self.relayProxy = nil
        pingTask?.cancel()
        pingTask = nil
        lock.unlock()

        guard !alreadyFailed else { return }
        sessionLog.error("session failed: \(message, privacy: .public)")
        emit(.phase(.failed(message)))
        // The video socket carries no handshake of its own and is authorized only by this
        // control session, so it dies with it.
        video?.cancel()
        relayProxy?.cancel()
        connection()?.cancel()
    }

    // MARK: - Helpers

    private func connection() -> ClientConnection? { lock.withLock { control } }

    private func emit(_ event: Event) { onEvent(event) }

    private static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw Failure.identity("no secure random")
        }
        return Data(bytes)
    }
}

extension ClientConnection {
    /// The remote address this connection was made to, so the video socket can be opened to
    /// the same place. Read from the connection itself rather than remembered by the caller,
    /// which is what makes a Bonjour endpoint survive the trip: it still carries the
    /// interface the host was discovered on.
    var remoteEndpoint: NWEndpoint? { currentEndpoint }
}
