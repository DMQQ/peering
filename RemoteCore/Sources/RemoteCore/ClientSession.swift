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

let clientSessionLog = Logger(subsystem: "pl.dmq.peering", category: "session")

/// The client half of the MacCast protocol: connect, authenticate, and stay usable.
/// Two sockets, always. ``control`` carries the handshake, commands, and the catalog;
/// ``video`` carries nothing but encoded pictures. A single stream would put a keyframe in front
/// of the next mouse move.
public final class ClientSession: @unchecked Sendable {

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

    // MARK: - Configuration held for the session's life

    let identity: SelfSignedIdentity
    let clientID: String
    let clientName: String
    let pins: ClientPinStore
    let onEvent: @Sendable (Event) -> Void

    /// The command queue, reused across reconnects so a gesture in flight is not stranded. Its sink reads the current control connection under the lock.
    let coalescer: CommandCoalescer

    // MARK: - State, all under `lock`

    let lock = NSLock()
    /// Has its own lock.
    let previewRequests = PreviewRequestTable()
    var _phase: Phase = .idle
    var _failureReason: FailureReason?
    var control: ClientConnection?
    var video: ClientConnection?
    var videoConnectTask: Task<Void, Never>?
    /// The wait before the next attempt at `video`, when armed. See ``VideoReconnectLadder``.
    var videoReconnectTask: Task<Void, Never>?
    var videoReconnectLadder = VideoReconnectLadder()
    /// Whether this client wants a picture at all. Set by `.setVideoEnabled`: a client that asked the Mac to stop capturing must not open the socket that restarts it.
    var wantsPicture = true
    var relayProxy: RelayControlProxy?
    /// Changes whenever a control attempt begins or ends. Work resumed from an `await` must
    /// still carry this value before it is allowed to install a relay proxy or send a hello.
    var connectGeneration: UInt64 = 0
    var usesRelayedSingleStream = false
    var _serverHello: ServerHello?
    var _catalog: CaptureCatalog?
    var _serverKey: Data?
    var state: HandshakeState = .idle
    var pingTask: Task<Void, Never>?
    /// The pings in flight and their window; the rules live in ``PingLedger`` and ``LatencyWindow`` so tests can drive timing.
    var pingLedger = PingLedger()
    var latency = LatencyWindow(length: ClientSession.latencyWindow)

    var videoWatchTask: Task<Void, Never>?
    var fallbackPolicy = VideoFallbackPolicy()
    var lastPictureAt: TimeInterval?
    var lastControlReplyAt: TimeInterval?
    var readyAt: TimeInterval?
    /// When the silence watchdog last ran, and when it last found the app had been frozen. Both are `ControlSilence`'s inputs and reset with the reply time.
    var lastSilenceCheckAt: TimeInterval?
    var silenceRestartedAt: TimeInterval?

    /// The rule that turns a silent control channel into a failure. See ``ControlSilence``. Nothing else reports it: a dead path leaves the picture frozen while every layer waits for an error.
    static let controlSilence = ControlSilence()
    /// Chunks in from the control channel, pictures out. Only fed from the control lane: the preferred transport carries whole frames.
    var videoChunks = VideoChunkReassembler()
    /// Chunks for the clipboard, kept apart from the lane above: both number frames from one, so a shared assembler would discard the other's partial frame.
    var clipboardChunks = ClipboardTransfer.reassembler()
    var clipboardFrameID: UInt32 = 0
    var _videoFallbackEnabled = true
    var announcedTransport: VideoTransport = .primary

    var relaySession: RelaySession?
    /// Whether this session wants the relay's datagram path and has not opened it yet. Opened when the Mac's stream description arrives: earlier races the Mac's first config against the key and starts the picture black.
    var wantsVideoDatagrams = false
    var videoDatagrams: VideoDatagramSocket?
    var directPathTask: Task<Void, Never>?
    /// The last path reported to the owner. Seeded with `.relay` since every session starts there.
    var reportedPath: DatagramPath = .relay

    var reportedDirectPath: DirectPath = .notTried
    /// The key, replay window and reassembler, set when the Mac answers ``MessageKind/videoKeyRequest``. Datagrams before that cannot be opened.
    var videoOpener: VideoDatagramOpener?

    /// Seals what this end puts on the datagram lane. One instance per session is a safety property: the counter is the ChaChaPoly nonce, so two sealers from one secret would reuse nonces.
    var videoSealer: VideoDatagramSealer?

    var pathPingLedger = PingLedger()
    var pathLatency = LatencyWindow(length: ClientSession.latencyWindow)
    var lanePingTask: Task<Void, Never>?

    var datagramFailures = 0
    var reportedDatagramFailure = false
    /// Pictures that arrived whole from the peer. A picture is about a hundred datagrams and completes only if every one lands, so 1% loss delivers about a third of pictures while the other counters climb.
    var picturesFromPeer = 0

    /// Whether this session's video could travel a path a network can block. Set by the caller from the kind of connection: a Bonjour Mac is on this network, while relay and typed-in addresses cross networks nobody controls.
    public var videoFallbackEnabled: Bool {
        get { lock.withLock { _videoFallbackEnabled } }
        set { lock.withLock { _videoFallbackEnabled = newValue } }
    }

    public var resumeSource: CaptureSource? {
        get { lock.withLock { _resumeSource } }
        set { lock.withLock { _resumeSource = newValue } }
    }
    var _resumeSource: CaptureSource?

    /// The device ID a first pairing was dialled by, checked against the Mac's answer.
    var pairingHostID: String?

    var ephemeral: P256.KeyAgreement.PrivateKey?
    var nonce: Data?
    var pairingTranscript: PairingTranscript?
    var remoteCommitment: Data?

    /// Where the handshake has got to; finer than ``Phase``.
    enum HandshakeState {
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

    final class ConnectionBox: @unchecked Sendable {
        private let lock = NSLock()
        private weak var session: ClientSession?

        func attach(_ session: ClientSession) { lock.withLock { self.session = session } }

        func send(_ command: RemoteCommand) {
            lock.withLock { session }?.sendNow(command)
        }
    }

    // MARK: - Observable state

    public var phase: Phase { lock.withLock { _phase } }
    /// Set with ``Phase/failed(_:)`` and cleared when a new connection begins.
    public var failureReason: FailureReason? { lock.withLock { _failureReason } }
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
            fail(Failure.describe(error), reason: FailureReason(error))
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
            supportsPointerReport: true,
            supportsAgentChat: true,
            supportsAgentPermissionModes: true,
            supportsAgentUsage: true,
            resumeSource: knowsHost ? resumeSource : nil,
            lostPairing: hostID != nil && !knowsHost ? true : nil
        ))

        lock.withLock {
            state = .awaitingServerHello
            _phase = .handshaking
        }
        emit(.phase(.handshaking))
        coalescer.start()
    }


    // MARK: - Pairing

    /// `secret` is the one from the Mac's QR code; digits typed by hand have none, and the Mac then asks its own user.
    public func confirmPairing(accepted: Bool, secret: Data? = nil) {
        lock.lock()
        let canConfirm = state == .awaitingUserConfirmation
        if accepted, canConfirm { state = .awaitingPairResult }
        let transcript = pairingTranscript
        lock.unlock()

        guard canConfirm else { return }
        let proof = secret.flatMap { secret in transcript.map { PairingSAS.proof(secret: secret, transcript: $0) } }
        connection()?.send(.pairConfirm, PairConfirm(accepted: accepted, proof: proof))

        guard accepted else {
            emit(.note("Pairing declined."))
            disconnect()
            return
        }
    }

    // MARK: - Ready

    /// Sends a command through ``CommandCoalescer``. The only path input takes, so the 120 Hz to 60 Hz rule and never dropping a `mouseUp` hold in one place.
    public func send(_ command: RemoteCommand) {
        guard isReady else { return }
        // The reconnect has to know which way the picture's switch was asked for, or a paused
        // client would dial a socket that makes the Mac start capturing again. Recorded here
        // rather than at the call site so the two can never be sent apart.
        if case .setVideoEnabled(let enabled) = command { notePictureRequested(enabled) }
        coalescer.enqueue(command)
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

    // MARK: - Liveness

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
            clientSessionLog.error("no answer within \(grace, privacy: .public)s of being asked; failing the session")
            self.fail("The Mac stopped answering. It may have moved networks, or the connection was interrupted.", reason: .unresponsiveAfterCheck)
        }
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


    // MARK: - Teardown

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

    // MARK: - Helpers

    func connection() -> ClientConnection? { lock.withLock { control } }

    func emit(_ event: Event) { onEvent(event) }

    static func randomBytes(_ count: Int) throws -> Data {
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
