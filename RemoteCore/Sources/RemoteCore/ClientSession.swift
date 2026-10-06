// CryptoKit is the system framework on Apple platforms; the open-source swift-crypto
// module is named `Crypto`.
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
/// Two sockets, always. ``control`` carries the handshake, commands, and the catalog;
/// ``video`` carries nothing but encoded pictures. A single stream would put a keyframe in front
/// of the next mouse move.
public final class ClientSession: @unchecked Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        case connecting
        case handshaking
        case confirming(code: String)
        case ready
        case failed(String)
        case disconnected

        public var holdsSession: Bool {
            switch self {
            case .connecting, .handshaking, .confirming, .ready: return true
            case .idle, .failed, .disconnected: return false
            }
        }
    }

    public struct DatagramCounts: Sendable, Equatable {
        public let received: Int
        public let fromPeer: Int
        public let refused: Int
        public let pictures: Int

        public init(received: Int, fromPeer: Int, refused: Int, pictures: Int) {
            self.received = received
            self.fromPeer = fromPeer
            self.refused = refused
            self.pictures = pictures
        }

        public var summary: String {
            "\(received) received, \(fromPeer) from the Mac, \(refused) unreadable, \(pictures) pictures"
        }
    }

    public var datagramCounts: DatagramCounts {
        lock.withLock {
            DatagramCounts(
                received: videoDatagrams?.receivedDatagrams ?? 0,
                fromPeer: videoDatagrams?.receivedFromPeer ?? 0,
                refused: datagramFailures,
                pictures: picturesFromPeer
            )
        }
    }

    public enum Event: Sendable {
        case phase(Phase)
        case host(ServerHello)
        case catalog(CaptureCatalog)
        case video(VideoEvent)
        /// Round-trip time of a control ping in ms. Not the picture's: the control connection goes through the relay in every session.
        case latency(milliseconds: Double)

        /// Round-trip time on the lane the picture arrives on, in ms; absent when there is no datagram lane. `fromPeer` says which path answered.
        case pathLatency(milliseconds: Double, fromPeer: Bool)
        /// What the relay's datagram lane has carried, every couple of seconds while one is open.
        case datagramCounts(DatagramCounts)
        case note(String)
        /// A standing condition on the Mac the user should see, or `nil`. Unlike ``note(_:)`` it stays up until the Mac says otherwise.
        case remoteNotice(NoticePayload?)
        /// What is on the host's pasteboard, on request or pushed when it changes. A payload because it may be a picture.
        case clipboard(ClipboardPayload)
        case textFocus(TextFocus)
        case fieldState(FieldState)
        case audio(AudioEvent)
        case terminal(TerminalEvent)
        case agent(AgentEvent)
        case relayQuotaExceeded
        /// The user stopped hosting on the Mac. Sent just before the session fails, so the app
        /// can treat that failure as final rather than a drop to reconnect from.
        case hostStopped
        /// Which way the picture is now arriving, sent only when the direct path takes over or is given up; absence means the relay.
        case path(DatagramPath)
        case directPath(DirectPath)
    }

    /// Which way the picture is arriving, as this end observes it. Only this direction, since the Mac decides what to send from what it receives.
    public enum DatagramPath: Sendable, Equatable {
        case relay
        case direct
    }

    /// What the attempt at a path straight to the Mac has come to. Failures are reported, since a NAT dropping packets and a failed lookup need different fixes.
    public enum DirectPath: Sendable, Equatable {
        case notTried
        case noAddress
        case probing(peer: String)
        /// The relay named an address this end cannot open a socket to: it renders a v4-mapped source as `::ffff:a.b.c.d`, which `getaddrinfo` refuses for `AF_INET`. Folding the mapping away is the fix.
        case addressUnusable(peer: String)
        case open(peer: String)

        public var summary: String {
            switch self {
            case .notTried: return "Not tried"
            case .noAddress: return "The relay has not said where the Mac is"
            case .probing(let peer): return "Knocking on \(peer), nothing back yet"
            case .addressUnusable(let peer): return "The relay named \(peer), which this phone cannot use"
            case .open(let peer): return "Straight to \(peer)"
            }
        }
    }

    public enum VideoEvent: Sendable {
        case connecting
        case config(VideoStreamConfig)
        case frame(EncodedVideoFrame)
        case ended(String)
        case transport(VideoTransport)
    }

    public enum AudioEvent: Sendable {
        case config(AudioStreamConfig)
        case frame(EncodedAudioFrame)
    }

    public enum Target: Sendable {
        case discovered(DiscoveredHost)
        case address(host: String, port: UInt16)
        /// A previously paired Mac reached through `peeringd` by stable device ID, with the entitlement (see ``RelayEntitlement``).
        case relay(hostID: String, name: String, entitlement: RelayEntitlement)

        /// A Mac never paired with, dialled by an ID typed or scanned. A separate case because the difference is a permission: ``relay(hostID:name:entitlement:)`` is refused with no stored pin. The ID is an address, not a credential; authentication is still the six digits.
        case relayPairing(hostID: String, name: String, entitlement: RelayEntitlement)

        public var displayName: String {
            switch self {
            case .discovered(let host): return host.name
            case .address(let host, let port): return "\(host):\(port)"
            case .relay(_, let name, _), .relayPairing(_, let name, _): return name
            }
        }

        /// The Mac's device ID for targets that name one, `nil` for a literal address. The reconnect ladder reads it to tell whether it is redialling the same Mac.
        public var hostID: String? {
            switch self {
            case .discovered(let host): return host.id
            case .relay(let hostID, _, _), .relayPairing(let hostID, _, _): return hostID
            case .address: return nil
            }
        }

        var isFirstPairing: Bool {
            if case .relayPairing = self { return true }
            return false
        }
    }

    public enum Failure: LocalizedError, Sendable {
        case busy
        case protocolMismatch(client: UInt16, host: UInt16)
        case commitmentMismatch
        case noServerKey
        /// The Mac answered and is not the one this device paired with: an impostor, or a Mac reset and paired again.
        case pinMismatch(hostID: String)
        /// Dialled by device ID with nothing in the pin store. Not ``pinMismatch``: there was no key to compare.
        case noPinOnFile(hostID: String)
        /// The Mac that answered through the relay is not the one whose ID was dialled. A routing check only: authentication is the code comparison.
        case hostIDMismatch(dialled: String, answered: String)
        case unexpected(MessageKind, expected: String)
        case identity(String)

        /// What to say about a network error: for an `NWError`, `localizedDescription` is `Network.NWError error 60`, not a sentence. The table is ``NetworkFailureText``.
        static func describe(_ error: Error) -> String {
            NetworkFailureText.describe(error)
        }

        public var errorDescription: String? {
            switch self {
            case .busy:
                return "This session is already connecting or connected."
            case .protocolMismatch(let client, let host):
                return "This Mac speaks protocol v\(host) and this app speaks v\(client). Update whichever is older."
            case .commitmentMismatch:
                // Reached only when a peer changed its contribution after seeing ours.
                return "The Mac's pairing reveal did not match its commitment."
            case .noServerKey:
                return "The Mac's certificate did not expose a public key, so it cannot be pinned."
            case .pinMismatch(let hostID):
                // The advice is part of the sentence rather than a second screen: the only way
                // forward is to forget this Mac and pair again. "pinned" is the word
                // ``HostPickerView`` looks for to give this its own title.
                return "Something at this address is not the Mac you paired with (\(hostID)). Its key does not match the key this iPhone pinned for it. If the Mac was reset, forget it here and pair again."
            case .noPinOnFile(let hostID):
                return "This iPhone has no pairing on file for that Mac (\(hostID)). Pair with it again, or forget it here and start over."
            case .hostIDMismatch(let dialled, let answered):
                return "A different Mac answered: \(answered), not \(dialled). Check that the code you scanned or typed came from the Mac you meant."
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

    /// The command queue, reused across reconnects so a gesture in flight is not stranded. Its sink reads the current control connection under the lock.
    private let coalescer: CommandCoalescer

    // MARK: - State, all under `lock`

    private let lock = NSLock()
    private var _phase: Phase = .idle
    private var control: ClientConnection?
    private var video: ClientConnection?
    private var videoConnectTask: Task<Void, Never>?
    /// The wait before the next attempt at `video`, when armed. See ``VideoReconnectLadder``.
    private var videoReconnectTask: Task<Void, Never>?
    private var videoReconnectLadder = VideoReconnectLadder()
    /// Whether this client wants a picture at all. Set by `.setVideoEnabled`: a client that asked the Mac to stop capturing must not open the socket that restarts it.
    private var wantsPicture = true
    private var relayProxy: RelayControlProxy?
    /// Changes whenever a control attempt begins or ends. Work resumed from an `await` must
    /// still carry this value before it is allowed to install a relay proxy or send a hello.
    private var connectGeneration: UInt64 = 0
    private var usesRelayedSingleStream = false
    private var _serverHello: ServerHello?
    private var _catalog: CaptureCatalog?
    private var _serverKey: Data?
    private var state: HandshakeState = .idle
    private var pingTask: Task<Void, Never>?
    /// The pings in flight and their window; the rules live in ``PingLedger`` and ``LatencyWindow`` so tests can drive timing.
    private var pingLedger = PingLedger()
    private var latency = LatencyWindow(length: ClientSession.latencyWindow)

    private var videoWatchTask: Task<Void, Never>?
    private var fallbackPolicy = VideoFallbackPolicy()
    private var lastPictureAt: TimeInterval?
    private var lastControlReplyAt: TimeInterval?
    private var readyAt: TimeInterval?

    /// The rule that turns a silent control channel into a failure. See ``ControlSilence``. Nothing else reports it: a dead path leaves the picture frozen while every layer waits for an error.
    private static let controlSilence = ControlSilence()
    /// Chunks in from the control channel, pictures out. Only fed from the control lane: the preferred transport carries whole frames.
    private var videoChunks = VideoChunkReassembler()
    /// Chunks for the clipboard, kept apart from the lane above: both number frames from one, so a shared assembler would discard the other's partial frame.
    private var clipboardChunks = ClipboardTransfer.reassembler()
    private var clipboardFrameID: UInt32 = 0
    private var _videoFallbackEnabled = true
    private var announcedTransport: VideoTransport = .primary

    private var relaySession: RelaySession?
    /// Whether this session wants the relay's datagram path and has not opened it yet. Opened when the Mac's stream description arrives: earlier races the Mac's first config against the key and starts the picture black.
    private var wantsVideoDatagrams = false
    private var videoDatagrams: VideoDatagramSocket?
    private var directPathTask: Task<Void, Never>?
    /// The last path reported to the owner. Seeded with `.relay` since every session starts there.
    private var reportedPath: DatagramPath = .relay

    private var reportedDirectPath: DirectPath = .notTried
    /// The key, replay window and reassembler, set when the Mac answers ``MessageKind/videoKeyRequest``. Datagrams before that cannot be opened.
    private var videoOpener: VideoDatagramOpener?

    /// Seals what this end puts on the datagram lane. One instance per session is a safety property: the counter is the ChaChaPoly nonce, so two sealers from one secret would reuse nonces.
    private var videoSealer: VideoDatagramSealer?

    private var pathPingLedger = PingLedger()
    private var pathLatency = LatencyWindow(length: ClientSession.latencyWindow)
    private var lanePingTask: Task<Void, Never>?

    private var datagramFailures = 0
    private var reportedDatagramFailure = false
    /// Pictures that arrived whole from the peer. A picture is about a hundred datagrams and completes only if every one lands, so 1% loss delivers about a third of pictures while the other counters climb.
    private var picturesFromPeer = 0

    /// Whether this session's video could travel a path a network can block. Set by the caller from the kind of connection: a Bonjour Mac is on this network, while relay and typed-in addresses cross networks nobody controls.
    public var videoFallbackEnabled: Bool {
        get { lock.withLock { _videoFallbackEnabled } }
        set { lock.withLock { _videoFallbackEnabled = newValue } }
    }

    public var resumeSource: CaptureSource? {
        get { lock.withLock { _resumeSource } }
        set { lock.withLock { _resumeSource = newValue } }
    }
    private var _resumeSource: CaptureSource?

    /// The device ID a first pairing was dialled by, checked against the Mac's answer.
    private var pairingHostID: String?

    private var ephemeral: P256.KeyAgreement.PrivateKey?
    private var nonce: Data?
    private var remoteCommitment: Data?

    /// Where the handshake has got to; finer than ``Phase``.
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
        // coalescer reads the connection through a box filled in immediately afterwards.
        let box = ConnectionBox()
        coalescer = CommandCoalescer(sink: { command in box.send(command) })
        box.attach(self)
    }

    deinit {
        pingTask?.cancel()
        videoWatchTask?.cancel()
        directPathTask?.cancel()
        lanePingTask?.cancel()
        videoConnectTask?.cancel()
        videoReconnectTask?.cancel()
        video?.cancel()
        videoDatagrams?.cancel()
        control?.cancel()
        relayProxy?.cancel()
        coalescer.stop()
    }

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
    public var serverKey: Data? { lock.withLock { _serverKey } }
    public var isReady: Bool { lock.withLock { state == .ready } }

    // MARK: - Connect

    /// Runs the client side of the handshake and returns once the outcome is known. Returns rather than throws: every failure already reaches the UI as a ``Phase/failed(_:)`` event.
    public func connect(to target: Target, timeout: TimeInterval = 10) async {
        guard let generation = beginConnecting() else {
            emit(.phase(.failed(Failure.busy.errorDescription ?? "busy")))
            return
        }
        emit(.phase(.connecting))

        let pinned: Data? = {
            if case .discovered(let host) = target { return pins.pin(for: host.id) }
            if case .relay(let hostID, _, _) = target { return pins.pin(for: hostID) }
            // Looked up and not insisted on: a first pairing has no pin; the handshake still checks a stored one.
            if case .relayPairing(let hostID, _, _) = target { return pins.pin(for: hostID) }
            return nil
        }()
        lock.withLock { pairingHostID = target.isFirstPairing ? target.hostID : nil }

        let connection = ClientConnection(label: "pl.dmq.peering.client.control")
        connection.onFrame = { [weak self] frame in self?.handle(frame) }
        connection.onClose = { [weak self] failure in self?.controlClosed(failure) }
        let installed = lock.withLock { () -> Bool in
            guard connectGeneration == generation else { return false }
            control = connection
            return true
        }
        guard installed else {
            connection.cancel()
            return
        }

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
            case .relay(let hostID, _, let entitlement):
                guard let pin = pins.pin(for: hostID) else {
                    throw Failure.noPinOnFile(hostID: hostID)
                }
                try await openRelayTunnel(
                    to: connection,
                    generation: generation,
                    hostID: hostID,
                    entitlement: entitlement,
                    pinnedServerKey: pin,
                    timeout: timeout
                )

            case .relayPairing(let hostID, _, let entitlement):
                try await openRelayTunnel(
                    to: connection,
                    generation: generation,
                    hostID: hostID,
                    entitlement: entitlement,
                    pinnedServerKey: pinned,
                    timeout: timeout
                )
            }
        } catch {
            // `disconnect()` invalidates the generation before cancelling whatever resources
            // already exist. An older dial returning afterwards is finished, not a new failure
            // belonging to the next session.
            if error is ConnectAttemptEnded || !isCurrentAttempt(connection, generation: generation) {
                connection.cancel()
                return
            }
            if let e = error as? RelaySignallingError,
               case .refused(let code, _) = e, code == "quotaExceeded" {
                emit(.relayQuotaExceeded)
            }
            fail(Failure.describe(error))
            return
        }

        guard isCurrentAttempt(connection, generation: generation) else {
            connection.cancel()
            return
        }

        lock.withLock { _serverKey = connection.observedServerKey }
        emit(.note("Connected over \(connection.negotiatedTLSVersion)"))

        connection.send(Frame(
            kind: .connectionRole,
            payload: Data([ConnectionRole.control.rawValue])
        ))

        // 2. Say who we are. `wantsPairing` is advisory: the Mac decides, because only the
        //    Mac knows its own pin store.
        let hostID = target.hostID
        let knowsHost = hostID.map { pins.pin(for: $0) != nil } ?? false
        connection.send(.clientHello, ClientHello(
            clientID: clientID,
            clientName: clientName,
            protocolVersion: ProtocolInfo.version,
            wantsPairing: !knowsHost,
            // Declared on every connection: it restrains the Mac, whose picture would otherwise land in a client that cannot read it.
            supportsClipboardImages: true,
            supportsTextFocus: true,
            supportsFieldState: true,
            supportsAgentChat: true,
            supportsAgentPermissionModes: true,
            supportsAgentUsage: true,
            resumeSource: knowsHost ? resumeSource : nil
        ))

        lock.withLock {
            state = .awaitingServerHello
            _phase = .handshaking
        }
        emit(.phase(.handshaking))
        coalescer.start()
    }

    /// Opens the relay's tunnel to a Mac and connects through it. Both relay targets share this; only the pin differs.
    private func openRelayTunnel(
        to connection: ClientConnection,
        generation: UInt64,
        hostID: String,
        entitlement: RelayEntitlement,
        pinnedServerKey: Data?,
        timeout: TimeInterval
    ) async throws {
        // Signed here, because this is where the key and the ID are both in hand. A failure to
        // sign is not a failure to connect: the relay falls back to metering the announced ID.
        let clientProof = try? RelayDeviceProof.makeClientProof(clientID: clientID, identity: identity)
        let allocation = try await RelaySignallingConnection.requestSession(
            at: ProtocolInfo.relaySignallingURL,
            hostID: hostID,
            clientID: clientID,
            entitlement: entitlement,
            clientProof: clientProof
        )
        try requireCurrentAttempt(connection, generation: generation)

        let proxy = RelayControlProxy(session: allocation)
        let endpoint: NWEndpoint
        do {
            endpoint = try await proxy.start()
        } catch {
            proxy.cancel()
            throw error
        }

        let installed = lock.withLock { () -> Bool in
            guard connectGeneration == generation, control === connection else { return false }
            relayProxy = proxy
            usesRelayedSingleStream = true
            // Kept because the relay told this end where the Mac's video datagrams
            // will come from and what to bind with, and there is no second chance to
            // ask: the signalling socket is closed the moment the session is returned.
            relaySession = allocation
            return true
        }
        guard installed else {
            proxy.cancel()
            throw ConnectAttemptEnded()
        }

        try await connection.connect(
            to: endpoint,
            identity: identity,
            pinnedServerKey: pinnedServerKey,
            timeout: timeout
        )
        try requireCurrentAttempt(connection, generation: generation)
    }

    /// Claims the session for one connect attempt. Returns `false` if it is already in use,
    /// so a double tap on "Connect" cannot leave two handshakes racing on one object.
    private func beginConnecting() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .idle, .failed:
            connectGeneration &+= 1
            state = .idle
            _phase = .connecting
            return connectGeneration
        default:
            return nil
        }
    }

    private struct ConnectAttemptEnded: Error {}

    private func isCurrentAttempt(_ connection: ClientConnection, generation: UInt64) -> Bool {
        lock.withLock { connectGeneration == generation && control === connection }
    }

    private func requireCurrentAttempt(
        _ connection: ClientConnection,
        generation: UInt64
    ) throws {
        guard isCurrentAttempt(connection, generation: generation) else {
            throw ConnectAttemptEnded()
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
            // Nothing is expected here: a frame now would mean the Mac raced ahead of a decision
            // the user has not made yet, so it is ignored rather than acted on.
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

        // Before the pin and before the pairing: is this the Mac that was dialled? Checked here
        // rather than at the relay, which routes by ID but answers for whatever holds it.
        if let dialled = lock.withLock({ pairingHostID }), hello.serverID != dialled {
            fail(Failure.hostIDMismatch(dialled: dialled, answered: hello.serverID).errorDescription ?? "")
            return
        }

        lock.withLock { _serverHello = hello }
        emit(.host(hello))

        // The pin is checked after the handshake because until `serverHello` there is no knowing which Mac this is. Nothing an impostor could use has been sent yet.
        if let stored = pins.pin(for: hello.serverID) {
            guard SPKI.matches(stored, serverKey) else {
                fail(Failure.pinMismatch(hostID: hello.serverID).errorDescription ?? "")
                return
            }
            emit(.note("The Mac's key matches the pin stored for it."))
        } else if hello.alreadyPaired {
            // Reached only when this device lost its pin store while the Mac kept its half. Not a
            // way in for an attacker: the Mac only answers `alreadyPaired` to a client whose
            // certificate it recognises, and our identity key is `…ThisDeviceOnly`, so a backup
            // restore cannot carry it here. Re-pin with the server key already verified over TLS.
            if pins.record(hostID: hello.serverID, publicKey: serverKey) {
                emit(.note("The Mac already knows this device. Pin restored. It will appear in Trusted Macs again."))
            } else {
                emit(.note("The Mac already knows this device, but the pin could not be saved. Keychain may be unavailable."))
            }
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
        // optionals is the kind of expression the type checker gives up on.
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

        // The transcript binds everything both sides exchanged, in a fixed order, with the Mac's
        // identity key taken from the certificate we actually received rather than from an
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

        let code = PairingSAS.code(for: transcript)
        lock.withLock {
            state = .awaitingUserConfirmation
            _phase = .confirming(code: code)
        }
        emit(.phase(.confirming(code: code)))
    }

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

        // Recorded only once the Mac has confirmed it stored its half: a pin the Mac never agreed
        // to would leave every later connection failing with a mismatch that looks like an attack.
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
        lock.withLock {
            state = .ready
            _phase = .ready
            // The watchdog's baseline until the first pong arrives. Without it, a session whose
            // first pong is late would be judged against a silence that began before it existed.
            readyAt = Self.monotonicNow()
        }
        emit(.phase(.ready))

        if lock.withLock({ usesRelayedSingleStream }) {
            emit(.video(.connecting))
            lock.withLock { wantsVideoDatagrams = true }
        } else {
            openVideoIfNeeded()
        }
        startPinging()
        startVideoWatch()
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
            reportLatency(for: frame)

        case .notice:
            // Decoded leniently on purpose: a notice is advisory, so a payload this build cannot
            // read costs the caption and not the connection.
            let payload = try? MessageCodec.decode(NoticePayload.self, from: frame.payload)
            emit(.remoteNotice(payload))

        case .error:
            let payload = try? MessageCodec.decode(ErrorPayload.self, from: frame.payload)
            if payload?.code == ErrorPayload.hostStoppedCode { emit(.hostStopped) }
            fail(payload?.message ?? "The Mac reported an error.")

        case .clipboardContent:
            handleClipboardContent(frame)

        case .textFocus:
            if let focus = try? MessageCodec.decode(TextFocus.self, from: frame.payload) {
                emit(.textFocus(focus))
            }

        case .fieldState:
            if let state = try? MessageCodec.decode(FieldState.self, from: frame.payload) {
                emit(.fieldState(state))
            }

        case .terminalEvent:
            if let event = try? MessageCodec.decode(TerminalEvent.self, from: frame.payload) {
                emit(.terminal(event))
            } else {
                sessionLog.error("could not decode a terminal event, so it is being dropped")
            }

        case .agentEvent:
            if let event = try? MessageCodec.decode(AgentEvent.self, from: frame.payload) {
                emit(.agent(event))
            } else {
                sessionLog.error("could not decode an agent event, so it is being dropped")
            }

        // The clipboard's chunks before the picture's: both arrive as the same frame kind, and without this guard the clipboard's pieces would be fed to the picture's assembler.
        case .videoChunk where VideoChunk.innerKind(of: frame) == .clipboardContent:
            handleClipboardChunk(frame)

        case .videoConfig, .videoFrame, .videoChunk, .audioConfig, .audioFrame:
            handleVideoFrame(frame, from: .control)

        case .videoKey:
            handleVideoKey(frame)

        default:
            sessionLog.notice("ignoring unexpected \(String(describing: frame.kind), privacy: .public) on a ready session")
        }
    }

    /// Sends a command through ``CommandCoalescer``. The only path input takes, so the 120 Hz to 60 Hz rule and never dropping a `mouseUp` hold in one place.
    public func send(_ command: RemoteCommand) {
        guard isReady else { return }
        // The reconnect has to know which way the picture's switch was asked for, or a paused
        // client would dial a socket that makes the Mac start capturing again. Recorded here
        // rather than at the call site so the two can never be sent apart.
        if case .setVideoEnabled(let enabled) = command { notePictureRequested(enabled) }
        coalescer.enqueue(command)
    }

    /// Records that the client asked for a picture, or for silence.
    /// A resume needs a socket to travel on: the Mac answers this command on the control channel,
    /// so a resume for a session whose video socket died during the pause reaches the Mac and
    /// changes nothing unless one is opened here.
    private func notePictureRequested(_ wanted: Bool) {
        lock.withLock { wantsPicture = wanted }
        if wanted { openVideoIfNeeded() }
    }

    public func selectCaptureSource(_ source: CaptureSource) {
        send(.setCaptureSource(source))
    }

    /// Sends a terminal request directly on the authenticated control stream. Unlike pointer
    /// moves, terminal bytes must never be coalesced or reordered.
    public func sendTerminal(_ request: TerminalRequest) {
        guard isReady else { return }
        connection()?.send(.terminalRequest, request)
    }

    /// Sends an agent chat request directly on the control stream, bypassing the coalescer: a coalesced prompt or approval would drop turns.
    public func sendAgent(_ request: AgentRequest) {
        guard isReady else { return }
        connection()?.send(.agentRequest, request)
    }

    /// Puts a picture on the Mac's pasteboard. Sent on the control channel, not the coalescer: it is not a gesture, and the transport's ordering keeps it ahead of later keystrokes. Larger than one message is split by ``ClipboardTransfer``.
    /// - Returns: `false` for a picture over the limit both ends carry, which nothing is sent for.
    @discardableResult
    public func pushClipboardImage(_ png: Data) -> Bool {
        guard png.count <= ClipboardLimits.maxImageBytes else { return false }
        guard isReady, let connection = connection() else { return false }
        guard let payload = try? MessageCodec.encode(RemoteCommand.pushClipboardImage(png: png)) else {
            return false
        }
        clipboardFrameID &+= 1
        let frames = ClipboardTransfer.frames(kind: .command, payload: payload, frameID: clipboardFrameID)
        guard !frames.isEmpty else { return false }
        for frame in frames { connection.send(frame) }
        return true
    }

    private func sendNow(_ command: RemoteCommand) {
        connection()?.send(command)
    }

    // MARK: - Liveness

    private static let pingInterval: Duration = .seconds(1)

    /// How long a round trip stays in the reported figure: a duration, not a count, so one bad round trip does not own it.
    private static let latencyWindow: TimeInterval = 10

    /// Probe attempts between two asks at the relay for the peer's address: twelve, one re-ask per three seconds when fast and one per minute once slowed.
    static let rediscoverEvery = 12

    private func startPinging() {
        lock.lock()
        guard pingTask == nil else { lock.unlock(); return }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard !Task.isCancelled, let self else { return }
                self.sendPing()
            }
        }
        pingTask = task
        lock.unlock()
    }

    private func sendPing() {
        let ping = lock.withLock {
            pingLedger.record(now: DispatchTime.now().uptimeNanoseconds)
        }
        // The payload is what makes the reply measurable. A Mac that does not echo it
        // answers empty, which the ledger reads as the oldest question still open.
        let payload = (try? MessageCodec.encode(PingPayload(sequence: ping.sequence))) ?? Data()
        connection()?.send(Frame(kind: .ping, payload: payload))
    }

    /// Fails the session unless the Mac answers within a few round trips, for when a session may look healthy with nothing under it (network just changed, app just resumed). The wait scales with the measured round trip so a same-Wi-Fi Mac is not made to wait out a relay-sized figure.
    public func verifyStillAnswering() {
        let askedAt = Self.monotonicNow()
        let (isReady, roundTrip) = lock.withLock { (state == .ready, latency.reported) }
        guard isReady else { return }
        let grace = Self.answerGrace(roundTripMilliseconds: roundTrip)
        sendPing()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard let self else { return }
            let silent = self.lock.withLock {
                self.state == .ready && (self.lastControlReplyAt ?? 0) < askedAt
            }
            guard silent else { return }
            sessionLog.error("no answer within \(grace, privacy: .public)s of being asked; failing the session")
            self.fail("The Mac stopped answering. It may have moved networks, or the connection was interrupted.")
        }
    }

    static func answerGrace(roundTripMilliseconds: Double?) -> TimeInterval {
        guard let roundTripMilliseconds else { return 1.0 }
        return min(1.5, max(0.4, roundTripMilliseconds * 4 / 1000 + 0.2))
    }

    /// The median of the last few round trips: a single ping flickers, and a mean would let one stalled ping drag the figure up.
    private func reportLatency(for frame: Frame) {
        let now = DispatchTime.now()
        let monotonic = Self.monotonicNow()

        let reported = lock.withLock { () -> Double? in
            // A pong is the only proof the control channel works; the fallback asks before moving the picture onto it.
            lastControlReplyAt = monotonic

            let sequence = (try? MessageCodec.decode(PingPayload.self, from: frame.payload))?.sequence
            guard let ping = pingLedger.answered(sequence: sequence) else { return nil }

            latency.add(
                Double(now.uptimeNanoseconds - ping.sentAtNanoseconds) / 1_000_000,
                at: monotonic
            )
            return latency.reported
        }

        guard let reported else { return }
        emit(.latency(milliseconds: reported))
    }

    // MARK: - Video

    /// Opens the second socket. Safe to call repeatedly; only the first call does anything.
    public func openVideoIfNeeded() {
        lock.lock()
        let alreadyOpen = video != nil
        // A relayed session has no second socket: its control connection is its video connection, and the loopback this would dial is a consumed one-shot listener, which fails as "video connection ended" on a streaming session. See ``usesRelayedSingleStream``.
        guard !alreadyOpen, !usesRelayedSingleStream, wantsPicture, state == .ready,
              let serverKey = _serverKey,
              let hello = _serverHello, let endpoint = control?.remoteEndpoint
        else {
            lock.unlock()
            return
        }
        // An attempt now is the one the ladder was waiting for, so the wait goes; the rung is not given back, since a socket that opens and dies again must be counted.
        let pending = videoReconnectTask
        videoReconnectTask = nil
        let connection = ClientConnection(label: "pl.dmq.peering.client.video")
        video = connection
        lock.unlock()
        pending?.cancel()

        connection.onFrame = { [weak self] frame in self?.handleVideoFrame(frame, from: .primary) }
        connection.onClose = { [weak self, weak connection] failure in
            guard let self, let connection else { return }
            let (connectTask, generation, wasCurrent) = self.lock.withLock {
                () -> (Task<Void, Never>?, UInt64, Bool) in
                guard self.video === connection else {
                    // A socket that something else replaced. Its close says nothing about the
                    // session, and arming a reconnect over the socket that replaced it would be
                    // dialling over a picture that is already there.
                    return (nil, self.connectGeneration, false)
                }
                self.video = nil
                let task = self.videoConnectTask
                self.videoConnectTask = nil
                return (task, self.connectGeneration, true)
            }
            connectTask?.cancel()
            // A cancellation is our own doing; reporting it would show "video connection ended" after a deliberate disconnect.
            guard failure != .cancelled else { return }
            // Belongs to the socket that was actually carrying the picture: reporting a replaced
            // socket's end would put "the picture has stopped" over a picture already flowing.
            guard wasCurrent else { return }
            self.emit(.video(.ended(failure.errorDescription ?? "video connection ended")))
            self.scheduleVideoReconnect(generation: generation)
        }

        emit(.video(.connecting))

        let task = Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            do {
                try await connection.connect(
                    to: endpoint,
                    identity: self.identity,
                    pinnedServerKey: self.pins.pin(for: hello.serverID) ?? serverKey,
                    timeout: 10
                )
            } catch {
                guard !Task.isCancelled else { return }
                self.emit(.video(.ended(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )))
                return
            }

            guard !Task.isCancelled,
                  // Asked again after the handshake because a pause can arrive during one: the role byte below makes the Mac start capturing.
                  self.lock.withLock({ self.video === connection && self.wantsPicture })
            else {
                connection.cancel()
                return
            }

            connection.send(Frame(
                kind: .connectionRole,
                payload: Data([ConnectionRole.video.rawValue])
            ))
            self.emit(.note("Video channel open; waiting for the Mac to start streaming."))
        }
        lock.withLock {
            if video === connection {
                videoConnectTask = task
            } else {
                task.cancel()
            }
        }
    }

    public func retryVideoAfterNetworkChange() {
        lock.lock()
        guard state == .ready, wantsPicture, !usesRelayedSingleStream else {
            lock.unlock()
            return
        }
        let pending = videoReconnectTask
        videoReconnectTask = nil
        videoReconnectLadder.reset()
        let stale = video
        video = nil
        let connecting = videoConnectTask
        videoConnectTask = nil
        lock.unlock()
        pending?.cancel()
        connecting?.cancel()
        stale?.cancel()
        openVideoIfNeeded()
    }

    /// Arms the next attempt at the video socket, if one is left. The guard refuses an ended or connecting session, a relayed one, and a client that asked for no picture.
    private func scheduleVideoReconnect(generation: UInt64) {
        lock.lock()
        // `video == nil` is in here because a socket replaced between the close and this call has nothing to dial for, and a rung spent on it is lost to the next real failure.
        guard videoReconnectTask == nil, video == nil, state == .ready, wantsPicture,
              !usesRelayedSingleStream
        else {
            lock.unlock()
            return
        }
        guard let delay = videoReconnectLadder.next() else {
            lock.unlock()
            // A session left up without its picture sat on "Stream paused" for good after a network
            // switch. Failing it hands the Mac to the session ladder, which redials on the new path.
            sessionLog.error("the video channel did not come back; failing the session")
            fail("The video channel did not come back.")
            return
        }
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            // The generation is re-read here and not merely at the arm above, because this is the
            // wait that can outlive what it was armed for. Whether the client still wants a picture
            // is deliberately *not* re-read: `openVideoIfNeeded` refuses to open one either way.
            let stillOurs = self.lock.withLock { () -> Bool in
                self.videoReconnectTask = nil
                return self.state == .ready && self.connectGeneration == generation
            }
            guard stillOurs else { return }
            self.openVideoIfNeeded()
        }
        // Assigned while the lock is still held: the task above may begin running the moment it is
        // created, and its first act under the lock is to clear this slot. Assigned outside it,
        // the body could clear a slot that had just been filled.
        videoReconnectTask = task
        lock.unlock()
    }

    /// Opens the relay's video datagram lane and asks the Mac for the key. The bind goes first: the relay forwards nothing to an address it has not been told about, and it learns it from a datagram of this end's token alone.
    private func startVideoDatagrams() {
        lock.lock()
        guard wantsVideoDatagrams, videoDatagrams == nil, let relay = relaySession else {
            lock.unlock()
            return
        }
        let generation = connectGeneration
        lock.unlock()
        // Built outside the lock: its init resolves the relay's name with a blocking getaddrinfo,
        // which on a slow LTE resolver held the main thread past the launch watchdog.
        let socket: VideoDatagramSocket
        do {
            socket = try VideoDatagramSocket(
                host: relay.videoHost,
                port: relay.videoPort,
                token: relay.videoToken,
                label: "pl.dmq.peering.client.video.datagrams"
            )
        } catch {
            // Not fatal: without this socket the picture stays on the control stream. The wish is dropped rather than retried, since the cause (a token or port off the wire contract) would repeat.
            lock.withLock { wantsVideoDatagrams = false }
            sessionLog.error("could not open the relay's video datagram socket: \(String(describing: error), privacy: .public)")
            emit(.note("Could not open the relay's video path; the picture will share the control channel."))
            return
        }
        lock.lock()
        guard wantsVideoDatagrams, videoDatagrams == nil, connectGeneration == generation else {
            lock.unlock()
            socket.cancel()
            return
        }
        videoDatagrams = socket
        datagramFailures = 0
        reportedDatagramFailure = false
        lock.unlock()

        socket.onDatagram = { [weak self] datagram, source in
            self?.handleDatagram(datagram, from: source)
        }
        socket.onFailure = { [weak self, weak socket] error in
            sessionLog.error("the video datagram socket failed: \(error.localizedDescription, privacy: .public)")
            guard let self, let socket else { return }
            self.videoDatagramSocketFailed(socket)
        }
        // The bind and the keepalive that repeats it. A NAT binding that expires is a session
        // that stops receiving video without anything on either end reporting a problem.
        socket.start()

        emit(.note("Remote session open; asking the Mac to send the picture directly."))
        connection()?.send(Frame(kind: .videoKeyRequest))
    }

    private func videoDatagramSocketFailed(_ socket: VideoDatagramSocket) {
        let tasks = lock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?)? in
            guard videoDatagrams === socket else { return nil }
            videoDatagrams = nil
            wantsVideoDatagrams = false
            videoOpener = nil
            videoSealer = nil
            reportedPath = .relay
            let direct = directPathTask
            let ping = lanePingTask
            directPathTask = nil
            lanePingTask = nil
            return (direct, ping)
        }
        guard let tasks else { return }
        tasks.0?.cancel()
        tasks.1?.cancel()
        socket.cancel()
        emit(.note("The relay's video path stopped responding."))
    }

    /// The Mac's answer to ``MessageKind/videoKeyRequest``. Only accepted once the socket exists, since a key with nowhere to receive would look like a working lane.
    private func handleVideoKey(_ frame: Frame) {
        guard let grant = try? MessageCodec.decode(VideoKeyGrant.self, from: frame.payload),
              grant.secret.count == VideoKeySchedule.secretSize
        else {
            sessionLog.error("the Mac sent a video key this build could not read")
            return
        }

        let opener = VideoKeySchedule(secret: grant.secret).opener(direction: .hostToClient)
        let accepted = lock.withLock { () -> Bool in
            guard videoDatagrams != nil else { return false }
            videoOpener = opener
            return true
        }
        guard accepted else { return }
        emit(.note("The Mac is sending video directly."))
        beginDirectPath(secret: grant.secret)
    }

    /// Asks the relay where the Mac is, then tries a path straight to it. Silent on every failure by design: a session that cannot reach its peer is on the relay, the ordinary case.
    private func beginDirectPath(secret: Data) {
        guard let pair = lock.withLock({ () -> (VideoDatagramSocket, RelaySession)? in
            guard let socket = videoDatagrams, let relay = relaySession else { return nil }
            return (socket, relay)
        }) else { return }
        let (socket, relay) = pair

        let schedule = VideoKeySchedule(secret: secret)
        guard let sealer = try? schedule.sealer(token: relay.videoToken, direction: .clientToHost)
        else {
            sessionLog.error("could not build the key for the direct video path, so the session stays on the relay")
            return
        }
        let laneStillExists = lock.withLock { () -> Bool in
            guard videoDatagrams === socket else { return false }
            videoSealer = sealer
            return true
        }
        guard laneStillExists else { return }

        let pingTask = makeLanePingTask(socket)
        let directTask = Task { [weak self] in
            guard let self,
                  self.lock.withLock({ self.videoDatagrams === socket })
            else { return }

            // Fast while there is any prospect, then slow for the rest of the session to recover a path a NAT mapping expiry took away. Each probe is sealed afresh: the counter is the AEAD nonce, so a reused probe would be discarded. Discovery repeats on the same cadence, since "no address yet" is the ordinary first answer.
            var attempt = 0
            while !Task.isCancelled {
                if attempt % Self.rediscoverEvery == 0 {
                    if let address = try? await RelaySignallingConnection.discoverPeer(
                        at: ProtocolInfo.relaySignallingURL,
                        videoToken: relay.videoToken
                    ) {
                        // Not fatal but said: an unparseable address would go unnoticed all session. ``sendDirect`` does nothing meanwhile rather than sending to the relay.
                        let peer = "\(address.host):\(address.port)"
                        do {
                            try socket.setDirectPeer(host: address.host, port: address.port)
                            self.reportDirectPath(.probing(peer: peer))
                        } catch {
                            self.reportDirectPath(.addressUnusable(peer: peer))
                        }
                    } else {
                        self.reportDirectPath(.noAddress)
                    }
                }

                let probe = self.sealOnVideoLane(kind: .directProbe, payload: Data())
                if !probe.isEmpty {
                    socket.sendDirect(probe) { _ in }
                }
                attempt += 1
                let interval: Duration = attempt <= 12 ? .milliseconds(250) : .seconds(5)
                try? await Task.sleep(for: interval)
            }
        }

        let previous = lock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?)? in
            guard videoDatagrams === socket else { return nil }
            let previous = (directPathTask, lanePingTask)
            directPathTask = directTask
            lanePingTask = pingTask
            return previous
        }
        guard let previous else {
            directTask.cancel()
            pingTask.cancel()
            return
        }
        previous.0?.cancel()
        previous.1?.cancel()
    }

    /// Measures the lane the picture is on, once a second. The control lane's figure is the relay's even when the picture is direct. Seals through ``sealOnVideoLane(kind:payload:)``: a second sealer would repeat nonces.
    private func makeLanePingTask(_ socket: VideoDatagramSocket) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard !Task.isCancelled, let self else { return }
                let ping = self.lock.withLock {
                    self.pathPingLedger.record(now: DispatchTime.now().uptimeNanoseconds)
                }
                let payload = (try? MessageCodec.encode(PingPayload(sequence: ping.sequence))) ?? Data()
                let sealed = self.sealOnVideoLane(kind: .ping, payload: payload)
                if !sealed.isEmpty { socket.send(sealed) { _ in } }
            }
        }
    }

    /// Seals one message onto the datagram lane through the single sealer: a second one would reuse AEAD nonces.
    private func sealOnVideoLane(kind: MessageKind, payload: Data) -> [Data] {
        lock.withLock {
            guard var sealer = videoSealer else { return [] }
            defer { videoSealer = sealer }
            return sealer.seal(kind: kind, payload: payload)
        }
    }

    private func notePathLatency(_ frame: Frame, from source: VideoDatagramSocket.Source) {
        let now = DispatchTime.now()
        let reported = lock.withLock { () -> Double? in
            let sequence = (try? MessageCodec.decode(PingPayload.self, from: frame.payload))?.sequence
            guard let ping = pathPingLedger.answered(sequence: sequence) else { return nil }
            pathLatency.add(
                Double(now.uptimeNanoseconds - ping.sentAtNanoseconds) / 1_000_000,
                at: Self.monotonicNow()
            )
            return pathLatency.reported
        }
        guard let reported else { return }
        emit(.pathLatency(milliseconds: reported, fromPeer: source != .relay))
    }

    /// One datagram from the relay, opened and fed into the path a whole frame takes. Reports a change of path once, not per datagram; the note goes with the change to direct only, since falling back is the ordinary case.
    private func noteDatagramPath(_ source: VideoDatagramSocket.Source) {
        var path: DatagramPath = .relay
        if case .peer(let host, let port) = source {
            path = .direct
            // The address the Mac is answering from: a NAT that moved mid-session is the ordinary case, and this end finds out.
            reportDirectPath(.open(peer: "\(host):\(port)"))
        }
        let changed = lock.withLock { () -> Bool in
            guard reportedPath != path else { return false }
            reportedPath = path
            return true
        }
        guard changed else { return }
        emit(.path(path))
        if path == .direct {
            emit(.note("The picture is coming straight from the Mac."))
        }
    }

    /// Says what the direct-path attempt has come to, once per change.
    private func reportDirectPath(_ outcome: DirectPath) {
        let changed = lock.withLock { () -> Bool in
            // A path that is open is not closed by a later look-up: the probing loop re-asks the relay periodically and would otherwise downgrade a path demonstrably carrying the picture. Only the announcement is suppressed.
            if case .open = reportedDirectPath, case .probing = outcome { return false }
            guard reportedDirectPath != outcome else { return false }
            reportedDirectPath = outcome
            return true
        }
        guard changed else { return }
        emit(.directPath(outcome))
    }

    private func handleDatagram(_ datagram: Data, from source: VideoDatagramSocket.Source) {
        let outcome = lock.withLock { () -> Result<Frame?, any Error> in
            guard let current = videoOpener else { return .success(nil) }
            // Mutated in place rather than copied: the replay window and the partial picture
            // being assembled *are* the state, and opening through a copy would forget both.
            var opener = current
            defer { videoOpener = opener }
            do { return .success(try opener.open(datagram)) } catch { return .failure(error) }
        }

        switch outcome {
        case .success(let frame):
            guard let frame else { return }
            noteDatagramPath(source)
            // A probe has done its job by opening: it proved the datagram came from the peer, and its source address is now where the Mac sends. Nothing to render.
            guard frame.kind != .directProbe else { return }
            // A lane ping's reply, timed here rather than passed on: everything else the opener
            // produces is a piece of the picture, and the renderer would try to read this as one.
            guard frame.kind != .pong else {
                notePathLatency(frame, from: source)
                return
            }
            lock.withLock { picturesFromPeer += 1 }
            handleVideoFrame(frame, from: .primary)

        case .failure(let error):
            // Counted, logged, and never dropped in silence: a datagram that does not authenticate
            // is the only thing that tells "this network is losing video" apart from "these two
            // ends are not speaking the same key", and the second has no other symptom at all.
            let (total, firstTime) = lock.withLock { () -> (Int, Bool) in
                datagramFailures += 1
                let first = !reportedDatagramFailure
                reportedDatagramFailure = true
                return (datagramFailures, first)
            }
            if total == 1 || total % 512 == 0 {
                sessionLog.error("""
                    a video datagram did not authenticate \
                    (\(String(describing: error), privacy: .public)) · \
                    \(total, privacy: .public) so far
                    """
                )
            }
            if firstTime {
                emit(.note("Some of the Mac's video datagrams could not be read; the picture may fall back to the control channel."))
            }
        }
    }

    /// One piece of a clipboard payload; a malformed piece costs the payload and nothing else. `transport` matters: a picture on the preferred transport during fallback is the only evidence the path works again. See ``VideoFallbackPolicy/notePrimaryPicture()``.
    private func handleClipboardChunk(_ frame: Frame) {
        let reassembled = lock.withLock { () -> Frame? in
            do {
                return try clipboardChunks.ingest(frame)
            } catch {
                sessionLog.error(
                    "dropping a malformed clipboard chunk: \(String(describing: error), privacy: .public)"
                )
                return nil
            }
        }
        guard let reassembled else { return }
        handleClipboardContent(reassembled)
    }

    /// A whole clipboard payload, decoded leniently: a newer Mac's payload this build cannot read is ignored rather than disconnecting.
    private func handleClipboardContent(_ frame: Frame) {
        guard let payload = try? MessageCodec.decode(ClipboardPayload.self, from: frame.payload) else {
            sessionLog.error("could not decode a clipboard payload")
            return
        }
        emit(.clipboard(payload))
    }

    private func handleVideoFrame(_ frame: Frame, from transport: VideoTransport) {
        // Chunked payloads are what the fallback looks like on the wire. One level only: a chunk of a chunk is refused.
        if frame.kind == .videoChunk {
            let reassembled = lock.withLock { () -> Frame? in
                do {
                    return try videoChunks.ingest(frame)
                } catch {
                    sessionLog.error("dropping a malformed video chunk: \(String(describing: error), privacy: .public)")
                    return nil
                }
            }
            guard let reassembled else { return }
            handleVideoFrame(reassembled, from: transport)
            return
        }

        switch frame.kind {
        case .videoConfig:
            note(pictureOn: transport)
            guard let config = try? MessageCodec.decode(VideoStreamConfig.self, from: frame.payload) else {
                sessionLog.error("could not decode a video config")
                return
            }
            // The picture is back, the only thing that counts as recovery: a socket that connected and said nothing is the failure the ladder exists for, so this is not cleared where the connection opens. Preferred lane only.
            if transport == .primary {
                lock.withLock { videoReconnectLadder.reset() }
            }
            emit(.video(.config(config)))
            // A described stream is what the datagram lane waits for. See ``wantsVideoDatagrams``.
            startVideoDatagrams()

        case .videoFrame:
            note(pictureOn: transport)
            do {
                emit(.video(.frame(try EncodedVideoFrame(decoding: frame.payload))))
            } catch {
                sessionLog.error("dropping a malformed video frame: \(String(describing: error), privacy: .public)")
            }

        case .error:
            let payload = try? MessageCodec.decode(ErrorPayload.self, from: frame.payload)
            emit(.video(.ended(payload?.message ?? "the Mac reported an error")))

        case .audioConfig:
            if let config = try? MessageCodec.decode(AudioStreamConfig.self, from: frame.payload) {
                emit(.audio(.config(config)))
            } else {
                sessionLog.error("could not decode an audio config, so this stream has no sound")
            }

        case .audioFrame:
            if let frame_decoded = try? EncodedAudioFrame(decoding: frame.payload) {
                emit(.audio(.frame(frame_decoded)))
            } else {
                sessionLog.error("dropping a malformed audio frame")
            }

        default:
            break
        }
    }

    // MARK: - Video transport

    /// Watches the picture for a blocked video transport, which looks from both sides like a working session. Rules are in ``VideoFallbackPolicy``.
    private func startVideoWatch() {
        lock.lock()
        // Measured from the moment the session became ready: three seconds of a healthy control channel with nothing arriving is the session-start probe.
        lastPictureAt = Self.monotonicNow()
        lastControlReplyAt = nil
        readyAt = nil
        fallbackPolicy.reset()
        guard videoWatchTask == nil else { lock.unlock(); return }
        let task = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.evaluateVideoTransport()
                self.failIfControlHasGoneQuiet()
                ticks += 1
                if ticks % 2 == 0 { self.reportDatagramCounts() }
            }
        }
        videoWatchTask = task
        lock.unlock()
    }

    /// Forgets the fallback's state and hands back the watch to cancel. Call with `lock` held and cancel the task after releasing it: `NSLock` is not recursive.
    private func stopVideoWatchLocked() -> Task<Void, Never>? {
        let task = videoWatchTask
        videoWatchTask = nil
        fallbackPolicy.reset()
        lastPictureAt = nil
        lastControlReplyAt = nil
        readyAt = nil
        videoChunks = VideoChunkReassembler()
        // A payload put back across two sessions would be made of two different Macs' pasteboards.
        clipboardChunks = ClipboardTransfer.reassembler()
        announcedTransport = .primary
        videoReconnectLadder.reset()
        // A new session starts wanting a picture. Left standing, a session that had been paused and
        // then reused would open no video socket for the whole of its second life.
        wantsPicture = true
        wantsVideoDatagrams = false
        videoOpener = nil
        // Dropped with the lane it belongs to. The sealer in particular: a new session mints a new
        // secret, so keeping this one would have the next session sealing under a key the Mac no
        // longer holds.
        videoSealer = nil
        pathPingLedger = PingLedger()
        pathLatency = LatencyWindow(length: ClientSession.latencyWindow)
        datagramFailures = 0
        reportedDatagramFailure = false
        lanePingTask?.cancel()
        lanePingTask = nil
        return task
    }

    /// Ends a session the network has stopped carrying without saying so: after a network change nothing fails, and the picture stays on its last frame. A session that recovers within the window is left alone.
    private func failIfControlHasGoneQuiet() {
        let now = Self.monotonicNow()
        lock.lock()
        let expired = Self.controlSilence.hasExpired(
            isReady: state == .ready,
            readyAt: readyAt,
            lastReplyAt: lastControlReplyAt,
            now: now
        )
        let silentSince = lastControlReplyAt ?? readyAt
        lock.unlock()

        guard expired, let silentSince else { return }
        sessionLog.error("the control channel has not answered for \(Int(now - silentSince), privacy: .public)s; failing the session")
        fail("The Mac stopped answering. It may have moved networks, or the connection was interrupted.")
    }

    private func evaluateVideoTransport() {
        let now = Self.monotonicNow()
        lock.lock()
        let decision = fallbackPolicy.advance(
            now: now,
            lastPictureAt: lastPictureAt,
            lastControlReplyAt: lastControlReplyAt,
            applies: _videoFallbackEnabled && state == .ready
        )
        lock.unlock()

        switch decision {
        case .none:
            break

        case .useControlChannel:
            // A request, not an instruction: the host will not move a picture it is not producing. The ask repeats on its own schedule, see ``VideoFallbackPolicy``, while the screen is told once.
            connection()?.send(.videoTransport, VideoTransportRequest(
                transport: .control,
                reason: "no picture for \(Int(VideoFallbackPolicy.silenceBeforeFallback))s "
                    + "on a control channel that is answering"
            ))
            // The counters ride with the note: a failed lane is only explicable with the numbers from when it failed, and settings cannot be opened mid-session.
            announce(.control, note: "No video is arriving. Asking the Mac to send the picture over the control channel. Datagram lane: \(datagramCounts.summary).")

        case .usePrimaryTransport:
            connection()?.send(.videoTransport, VideoTransportRequest(
                transport: .primary,
                reason: "video is arriving again on the transport it prefers"
            ))
            announce(.primary, note: "Video is arriving again on the faster path. Datagram lane: \(datagramCounts.summary).")
        }
    }

    /// Hands the lane's counters to the watcher. Silent until there is a lane: zeros would read as a present, idle lane.
    private func reportDatagramCounts() {
        guard lock.withLock({ videoDatagrams != nil }) else { return }
        emit(.datagramCounts(datagramCounts))
    }

    /// Says which lane the picture is on, once per change: the ask repeats but the note is read by a person.
    private func announce(_ transport: VideoTransport, note: String) {
        let changed = lock.withLock { () -> Bool in
            guard announcedTransport != transport else { return false }
            announcedTransport = transport
            return true
        }
        guard changed else { return }
        emit(.video(.transport(transport)))
        emit(.note(note))
    }

    private func note(pictureOn transport: VideoTransport) {
        lock.withLock {
            lastPictureAt = Self.monotonicNow()
            if transport == .primary { fallbackPolicy.notePrimaryPicture() }
        }
    }

    /// Monotonic seconds: `DispatchTime` rather than `Date`, so a clock sync cannot look like silence.
    private static func monotonicNow() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: - Teardown

    private func controlClosed(_ failure: ClientConnection.Failure) {
        lock.lock()
        let wasFailed = state == .failed
        let deliberate = failure == .cancelled
        lock.unlock()

        if deliberate {
            guard !wasFailed else { return }
            emit(.phase(.disconnected))
            return
        }
        // The Mac's own explanation arrives as an `.error` frame immediately before the
        // close. Reporting the close as well would replace a sentence the user can act on
        // with "connection reset".
        guard !wasFailed else { return }
        fail(failure.errorDescription ?? "The connection ended.")
    }

    public func disconnect() {
        lock.lock()
        connectGeneration &+= 1
        let control = self.control
        let video = self.video
        let videoConnect = self.videoConnectTask
        let videoReconnect = self.videoReconnectTask
        let relayProxy = self.relayProxy
        let datagrams = self.videoDatagrams
        self.control = nil
        self.video = nil
        self.videoConnectTask = nil
        self.videoReconnectTask = nil
        self.relayProxy = nil
        self.videoDatagrams = nil
        self.relaySession = nil
        directPathTask?.cancel()
        directPathTask = nil
        reportedPath = .relay
        usesRelayedSingleStream = false
        pingTask?.cancel()
        pingTask = nil
        let videoWatch = stopVideoWatchLocked()
        state = .idle
        _phase = .disconnected
        ephemeral = nil
        nonce = nil
        remoteCommitment = nil
        lock.unlock()

        videoWatch?.cancel()
        videoConnect?.cancel()
        videoReconnect?.cancel()
        coalescer.flush()
        video?.cancel()
        datagrams?.cancel()
        control?.cancel()
        relayProxy?.cancel()
        emit(.phase(.disconnected))
    }

    private func fail(_ message: String) {
        lock.lock()
        // The first failure is the one that counts: a connection that fails is reported twice (the transport's close handler and the `catch` in `connect`), and this guard keeps the property and event stream from holding two sentences.
        guard state != .failed else {
            lock.unlock()
            return
        }
        connectGeneration &+= 1
        state = .failed
        _phase = .failed(message)
        let video = self.video
        let videoConnect = self.videoConnectTask
        let videoReconnect = self.videoReconnectTask
        let control = self.control
        let relayProxy = self.relayProxy
        let datagrams = self.videoDatagrams
        self.video = nil
        self.videoConnectTask = nil
        self.videoReconnectTask = nil
        self.control = nil
        self.relayProxy = nil
        self.videoDatagrams = nil
        self.relaySession = nil
        directPathTask?.cancel()
        directPathTask = nil
        reportedPath = .relay
        pingTask?.cancel()
        pingTask = nil
        let videoWatch = stopVideoWatchLocked()
        lock.unlock()

        videoWatch?.cancel()
        videoConnect?.cancel()
        videoReconnect?.cancel()
        sessionLog.error("session failed: \(message, privacy: .public)")
        emit(.phase(.failed(message)))
        // The video socket carries no handshake of its own and is authorized only by this
        // control session, so it dies with it. The datagram lane is the same arrangement one
        // step further out: the relay only forwards it while the session it belongs to lives.
        video?.cancel()
        datagrams?.cancel()
        relayProxy?.cancel()
        control?.cancel()
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
    /// The remote address this connection was made to, so the video socket can be opened to the same
    /// place. Read from the connection itself rather than remembered by the caller, so a Bonjour
    /// endpoint still carries the interface the host was discovered on.
    var remoteEndpoint: NWEndpoint? { currentEndpoint }
}
