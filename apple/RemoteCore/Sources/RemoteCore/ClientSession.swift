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
    var _failureCause: FailureCause?
    var control: ClientConnection?
    var video: ClientConnection?
    var videoConnectTask: Task<Void, Never>?
    /// The wait before the next attempt at `video`, when armed. See ``VideoReconnectLadder``.
    var videoReconnectTask: Task<Void, Never>?
    var videoReconnectLadder = VideoReconnectLadder()
    /// Whether this client wants a picture at all. Set by `.setVideoEnabled`: a client that asked the Mac to stop capturing must not open the socket that restarts it.
    var wantsPicture = true
    /// Set while the app has told the Mac it left the foreground: the Mac stops the picture on purpose, which the transport watch must not read as a blocked path.
    var clientNotice = ClientStateNotice()
    var clientBackgrounded: Bool { clientNotice.sent }
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
    /// Of the connection that was live at the end: `becomeReady` starts it again.
    var videoDelivery = VideoDeliveryRecord()
    var lastControlReplyAt: TimeInterval?
    var readyAt: TimeInterval?
    /// The last stage entered, for ``FailureDiagnosis``.
    var connectStage: ConnectStage = .resolving
    var connectStartedAt: TimeInterval?
    var _millisecondsToReady: Int?
    var _failureDiagnosis: FailureDiagnosis?
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

    /// Sent in the hello so the Mac can tag its own events with the phone's. See ``ClientHello/sessionRef``.
    public var sessionRef: String? {
        get { lock.withLock { _sessionRef } }
        set { lock.withLock { _sessionRef = newValue } }
    }
    var _sessionRef: String?

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
    /// What to tell the person, from a closed set, when the failure has a wording that needs no names or numbers. Set and cleared with ``failureReason``.
    public var failureCause: FailureCause? { lock.withLock { _failureCause } }
    /// Set with ``failureReason`` and cleared with it.
    public var failureDiagnosis: FailureDiagnosis? { lock.withLock { _failureDiagnosis } }
    /// From the dial to ``Phase/ready``, `nil` before the session is ready.
    public var millisecondsToReady: Int? { lock.withLock { _millisecondsToReady } }
    public var serverHello: ServerHello? { lock.withLock { _serverHello } }
    public var videoDeliveryRecord: VideoDeliveryRecord { lock.withLock { videoDelivery } }
    public var catalog: CaptureCatalog? { lock.withLock { _catalog } }
    public var serverKey: Data? { lock.withLock { _serverKey } }
    public var isReady: Bool { lock.withLock { state == .ready } }

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
