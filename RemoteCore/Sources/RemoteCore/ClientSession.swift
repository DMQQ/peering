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
///
/// The client's counterpart to the host's `HostSession`, deliberately the same shape: one state
/// machine driven by frames from one connection, so the handshake's ordering guarantees are
/// enforced in exactly one place.
///
/// Two sockets, always. ``control`` carries the handshake, commands, and the catalog;
/// ``video`` carries nothing but encoded pictures. A single stream would put a keyframe in front
/// of the next mouse move.
public final class ClientSession: @unchecked Sendable {
    /// Where the session is in its life. Coarse on purpose: the UI renders this directly.
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
        public var holdsSession: Bool {
            switch self {
            case .connecting, .handshaking, .confirming, .ready: return true
            case .idle, .failed, .disconnected: return false
            }
        }
    }

    /// What the relay's datagram lane has carried so far, cumulative for the session.
    public struct DatagramCounts: Sendable, Equatable {
        /// Everything the socket read, from the relay and from the peer alike.
        public let received: Int
        /// The subset that arrived straight from the peer rather than through the relay.
        public let fromPeer: Int
        /// Datagrams that arrived and could not be opened: a corrupted packet, or two ends that
        /// are not speaking the same key.
        public let refused: Int
        /// Pictures assembled whole from those datagrams.
        public let pictures: Int

        public init(received: Int, fromPeer: Int, refused: Int, pictures: Int) {
            self.received = received
            self.fromPeer = fromPeer
            self.refused = refused
            self.pictures = pictures
        }

        /// One line, for a log a person reads.
        public var summary: String {
            "\(received) received, \(fromPeer) from the Mac, \(refused) unreadable, \(pictures) pictures"
        }
    }

    /// What the lane has carried, for the log and the diagnostics screen.
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

    /// What the session tells its owner. Every case is a value, so the UI can apply these on
    /// whatever actor it likes.
    public enum Event: Sendable {
        case phase(Phase)
        case host(ServerHello)
        case catalog(CaptureCatalog)
        case video(VideoEvent)
        /// Round-trip time of a control ping, in milliseconds.
        ///
        /// Not the picture's round trip: the control connection goes through the relay in every
        /// session, punched or not. See ``pathLatency(milliseconds:fromPeer:)``.
        case latency(milliseconds: Double)

        /// Round-trip time on the lane the picture is arriving on, in milliseconds.
        ///
        /// `fromPeer` says which path answered: the one the two ends opened between themselves, or
        /// the relay's datagram lane. The reply carries it because the path is a property of where
        /// the datagram came *from*.
        ///
        /// Absent when there is no datagram lane at all, which is most sessions at their start and
        /// some for their whole life. A reader with no path figure falls back to
        /// ``latency(milliseconds:)``.
        case pathLatency(milliseconds: Double, fromPeer: Bool)
        /// What the relay's datagram lane has carried, every couple of seconds while one is open.
        ///
        /// Four numbers because a lane fails in four distinguishable ways: nothing arriving is a
        /// network that will not carry it, arriving and refused is this end failing to open them,
        /// arriving with far too few pictures is packet loss, and none of those is a working lane.
        case datagramCounts(DatagramCounts)
        /// Diagnostics worth surfacing without failing: a pin that was accepted, a video
        /// channel that connected but has not produced a stream yet.
        case note(String)
        /// A standing condition on the Mac that the user should see, or `nil` when there is
        /// none. Unlike ``note(_:)`` it is a caption for the picture, and it stays up until the
        /// Mac says otherwise.
        case remoteNotice(NoticePayload?)
        /// What is on the host's pasteboard, delivered after a
        /// ``RemoteCommand/requestClipboard`` or pushed when the Mac's pasteboard changes.
        ///
        /// A payload rather than a string: a pasteboard holds a picture as readily as a line of text.
        case clipboard(ClipboardPayload)
        /// The Mac's keyboard focus moved, and whether it landed somewhere that takes typing.
        case textFocus(TextFocus)
        /// An audio stream event from the video channel.
        case audio(AudioEvent)
        /// A reconnectable shell session event from the authenticated control channel.
        case terminal(TerminalEvent)
        /// The relay's free allowance for this client ID is exhausted for the current period.
        case relayQuotaExceeded
        /// Which way the picture is now arriving, once it has changed from the way it started.
        ///
        /// Sent when the direct path takes over and when it is given up, and only then: every
        /// session begins on the relay, so the absence of this event means the ordinary case.
        case path(DatagramPath)
        /// What the attempt at a path straight to the Mac has come to. See ``DirectPath``.
        case directPath(DirectPath)
    }

    /// Which way the picture is arriving, as this end observes it.
    ///
    /// Only this direction is observed, which is enough: the Mac decides what to send from what it
    /// receives, so a punched path costs no new control messages.
    public enum DatagramPath: Sendable, Equatable {
        case relay
        case direct
    }

    /// What the attempt at a path straight to the Mac has come to.
    ///
    /// The failure cases are reported rather than silenced: a NAT that drops packets and a lookup
    /// that never answered are different problems with different fixes.
    public enum DirectPath: Sendable, Equatable {
        /// There is nothing to try: no datagram socket, or the session is not on that lane.
        case notTried
        /// The relay has not said where the Mac is. The ordinary first answer, and a problem if it
        /// is still the answer a minute in.
        case noAddress
        /// An address came back and probes are going out to it. Nothing has arrived from the Mac at
        /// that address, so the packets are being dropped on the way.
        case probing(peer: String)
        /// The relay named an address this end cannot even open a socket to.
        ///
        /// The relay renders a dual-stack socket's v4-mapped source as `::ffff:a.b.c.d`, which
        /// `getaddrinfo` refuses for an `AF_INET` socket. Folding the mapping away is the fix.
        case addressUnusable(peer: String)
        /// The Mac is answering directly and the picture is coming from it.
        case open(peer: String)

        /// The one line a settings row shows.
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
        /// Which channel the picture is coming down, after the client's own fallback decision.
        ///
        /// Reported rather than inferred by the UI, because the two lanes look identical on
        /// screen.
        case transport(VideoTransport)
    }

    public enum AudioEvent: Sendable {
        case config(AudioStreamConfig)
        case frame(EncodedAudioFrame)
    }

    /// How to reach a Mac. Both paths end in the same TLS + pairing handshake; they differ
    /// only in whether an address had to be resolved first.
    public enum Target: Sendable {
        /// Found over Bonjour. Carries the interface it was discovered on, which is the path
        /// that actually works on a Mac with several.
        case discovered(DiscoveredHost)
        /// A literal address. What the simulator needs, since Bonjour there is unreliable, and
        /// the honest fallback for a network that blocks multicast.
        case address(host: String, port: UInt16)
        /// A previously paired Mac reached through `peeringd` by its stable device ID.
        ///
        /// `entitlement` is what this device can say about what it has bought: the receipt Apple
        /// signed for the live subscription, the plan it claims, and the relay's own key. See
        /// ``RelayEntitlement``.
        case relay(hostID: String, name: String, entitlement: RelayEntitlement)

        /// A Mac this device has never paired with, dialled by an ID the user typed or scanned.
        ///
        /// A separate case rather than a flag, because the difference is a permission:
        /// ``relay(hostID:name:entitlement:)`` is refused when no pin is stored, while what licenses
        /// this case is that a person read the ID off the other machine. Spelled as its own case,
        /// every switch over ``Target`` has to say what it does about an unpaired Mac.
        ///
        /// An address, not a credential: a device ID is not a secret, the Mac shows it, the relay
        /// routes by it, and anyone who can read a QR code can repeat it. The authentication is
        /// still the six digits both screens show and the two people compare.
        case relayPairing(hostID: String, name: String, entitlement: RelayEntitlement)

        public var displayName: String {
            switch self {
            case .discovered(let host): return host.name
            case .address(let host, let port): return "\(host):\(port)"
            case .relay(_, let name, _), .relayPairing(_, let name, _): return name
            }
        }

        /// The Mac's device ID, for the targets that name one rather than an address.
        ///
        /// `nil` for a literal address, which says nothing about *which* Mac is at it. Read by the
        /// reconnect ladder, which has to know whether the Mac it is dialling is the one it is
        /// replacing: what belongs to the Mac survives a dial, what belongs to the attempt does not.
        public var hostID: String? {
            switch self {
            case .discovered(let host): return host.id
            case .relay(let hostID, _, _), .relayPairing(let hostID, _, _): return hostID
            case .address: return nil
            }
        }

        /// Whether this dial is a first pairing, where no pin is expected to exist yet.
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
        /// The Mac answered, and it is not the one this device paired with.
        ///
        /// Either an impostor, or a Mac that was reset and paired again since.
        case pinMismatch(hostID: String)
        /// Dialled by device ID with nothing in the pin store to back the claim.
        ///
        /// Deliberately *not* ``pinMismatch``: a mismatch means a key was compared and failed, this
        /// means there was no key to compare. Reachable through the relay, where a device ID is
        /// enough to dial with.
        case noPinOnFile(hostID: String)
        /// The Mac that answered through the relay is not the one whose ID was dialled.
        ///
        /// A routing check, and nothing more: the relay routes by device ID, so a Mac that reports a
        /// different one means the user typed or scanned the wrong Mac's code. It is deliberately
        /// *not* doing any of the authenticating, because the ID is a name the relay and the Mac
        /// both know; only the code comparison covers a relay that answers with something it is not.
        case hostIDMismatch(dialled: String, answered: String)
        case unexpected(MessageKind, expected: String)
        case identity(String)

        /// What to say about an error that came from the network rather than from the protocol.
        ///
        /// The table lives in ``NetworkFailureText``, called from both places that can fail this way.
        /// For an `NWError`, `error.localizedDescription` is not a sentence but the string
        /// `Network.NWError error 60`.
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
                // Never a key comparison: there is nothing on file for this ID at all.
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

    /// The command queue, created once and reused across reconnects so a gesture in flight is
    /// not stranded. Its sink reads the current control connection under the lock, so a queued
    /// command can never be delivered to a dead socket.
    private let coalescer: CommandCoalescer

    // MARK: - State, all under `lock`

    private let lock = NSLock()
    private var _phase: Phase = .idle
    private var control: ClientConnection?
    private var video: ClientConnection?
    /// The asynchronous open for `video`, so ending the session also ends a socket that is
    /// still resolving or handshaking rather than only one that has reached `.ready`.
    private var videoConnectTask: Task<Void, Never>?
    /// The wait before the next attempt at `video`, when one is armed.
    ///
    /// A video socket is a lane of its own and can go without the session going with it, so
    /// something has to put it back. ``VideoReconnectLadder`` decides when.
    private var videoReconnectTask: Task<Void, Never>?
    /// How many attempts the picture has cost so far. See ``VideoReconnectLadder``.
    private var videoReconnectLadder = VideoReconnectLadder()
    /// Whether this client wants a picture at all, as opposed to wanting one on a working socket.
    ///
    /// Set from the one command that says otherwise, `.setVideoEnabled`, on its way out: a client
    /// that asked the Mac to stop capturing must not open the socket that would start it again.
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
    /// The pings in flight, and the window they are measured into. Both rules live in ``PingLedger``
    /// and ``LatencyWindow`` so a test can drive them: every interesting case in them is about
    /// *timing*, and timing is the one thing a test cannot wait for.
    private var pingLedger = PingLedger()
    private var latency = LatencyWindow(length: ClientSession.latencyWindow)

    /// The video transport watchdog: the rules, and the three things it watches.
    private var videoWatchTask: Task<Void, Never>?
    private var fallbackPolicy = VideoFallbackPolicy()
    /// When a picture last arrived, on either lane. The fallback's whole input.
    private var lastPictureAt: TimeInterval?
    /// When the control channel last answered anything.
    private var lastControlReplyAt: TimeInterval?
    /// When the handshake finished, which is what the silence watchdog counts from until the
    /// first pong arrives.
    private var readyAt: TimeInterval?

    /// The rule that turns a silent control channel into a failure. See ``ControlSilence``.
    ///
    /// Nothing else reports it: a session that stopped being carried stays frozen on its last decoded
    /// frame while every layer above waits for an error that never comes. `lastControlReplyAt` alone
    /// is not enough, because the fallback policy reads it to decline to move the picture onto a
    /// channel that is itself failing.
    private static let controlSilence = ControlSilence()
    /// Chunks in from the control channel, pictures out. Only ever fed from the control lane:
    /// the preferred transport carries whole frames, which need no reassembly.
    private var videoChunks = VideoChunkReassembler()
    /// Chunks in from the control channel for the clipboard, kept apart from the lane above.
    ///
    /// Two assemblers and not one: both lanes arrive as the same frame kind and each numbers its
    /// frames from one, so a shared assembler would read the other lane's next frame as a reason to
    /// throw away what it was holding.
    private var clipboardChunks = ClipboardTransfer.reassembler()
    /// Which clipboard frame is being cut up on the way out, so the far end can tell two apart.
    private var clipboardFrameID: UInt32 = 0
    private var _videoFallbackEnabled = true
    /// The lane the UI has already been told about, so a repeated request is not a repeated note.
    private var announcedTransport: VideoTransport = .primary

    /// The relay's allocation for this session, when there is one. Its video host and port are
    /// where the Mac's datagrams come from, and its token is what this end binds with.
    private var relaySession: RelaySession?
    /// Whether this session wants the relay's datagram path, and has not opened it yet.
    ///
    /// The lane is opened when the Mac's description of the stream has arrived, not when the session
    /// becomes ready, because the description is what the Mac sends it on: opening earlier races the
    /// Mac's first config against the key that opens it, and a description arriving before the grant
    /// starts the picture black.
    private var wantsVideoDatagrams = false
    /// The socket the Mac's sealed video datagrams arrive on. Nil on every session that is
    /// not a relayed one, and nil until the lane is opened.
    private var videoDatagrams: VideoDatagramSocket?
    /// The task that asks the relay where the Mac is and then keeps probing it.
    ///
    /// Held so it can be cancelled with the socket.
    private var directPathTask: Task<Void, Never>?
    /// The last path reported to the owner, so a change is reported once rather than per datagram.
    /// Seeded with `.relay` rather than left optional: every session starts on the relay, so the
    /// first datagram to arrive is not news.
    private var reportedPath: DatagramPath = .relay

    /// The last thing the direct-path attempt reported, so the same state is not emitted twice.
    private var reportedDirectPath: DirectPath = .notTried
    /// The other half of that lane: the key, the replay window and the reassembler. Set when the
    /// Mac's answer to ``MessageKind/videoKeyRequest`` arrives. A datagram that arrives before it
    /// cannot be opened, which is why the Mac's first few frames after a grant are wasted.
    private var videoOpener: VideoDatagramOpener?

    /// Seals what this end puts on the datagram lane: the probes, and the lane's own pings.
    ///
    /// One instance for the whole session, and that is a safety property: the sealer's counter *is*
    /// the ChaChaPoly nonce, so two sealers from one secret for one direction would encrypt under
    /// the same key with the same nonces. Everything that seals onto this lane goes through this one
    /// value, under the session's lock.
    private var videoSealer: VideoDatagramSealer?

    /// The pings in flight on the datagram lane, and the window they are measured into.
    ///
    /// Separate from the control lane's: they measure different paths, and a session can have both
    /// at once.
    private var pathPingLedger = PingLedger()
    private var pathLatency = LatencyWindow(length: ClientSession.latencyWindow)
    private var lanePingTask: Task<Void, Never>?

    /// How many datagrams did not authenticate, and whether the user has been told.
    ///
    /// The rate is the interesting case: one is a corrupted packet, and one per picture is two
    /// ends that are not speaking the same key.
    private var datagramFailures = 0
    private var reportedDatagramFailure = false
    /// Pictures that arrived whole from the peer, and the number that matters most.
    ///
    /// A picture is cut into roughly a hundred datagrams, so a frame completes only if *every* one
    /// lands: a lane losing one datagram in a hundred delivers about a third of its pictures, and
    /// one losing one in twenty delivers almost none, while the counters beside this one climb.
    private var picturesFromPeer = 0

    /// Whether this session's video could be travelling a path that a network can block.
    ///
    /// Set by the caller from the *kind* of connection, because that is knowledge the session does
    /// not have: a Mac found over Bonjour is on this network, where a missing picture is a different
    /// problem, while a relay session and a typed-in address both cross networks nobody here
    /// controls.
    public var videoFallbackEnabled: Bool {
        get { lock.withLock { _videoFallbackEnabled } }
        set { lock.withLock { _videoFallbackEnabled = newValue } }
    }

    /// Sent in the hello so the Mac starts capturing it on arrival. See ``ClientHello/resumeSource``.
    public var resumeSource: CaptureSource? {
        get { lock.withLock { _resumeSource } }
        set { lock.withLock { _resumeSource = newValue } }
    }
    private var _resumeSource: CaptureSource?

    /// The device ID a first pairing was dialled by, so the answer can be checked against it.
    ///
    /// Set by ``connect(to:timeout:)`` for every attempt, `nil` for the targets where the ID is
    /// not the user's to give, and read once, when the Mac says who it is.
    private var pairingHostID: String?

    private var ephemeral: P256.KeyAgreement.PrivateKey?
    private var nonce: Data?
    private var remoteCommitment: Data?

    /// Where the handshake has got to. Separate from ``Phase``: the UI does not distinguish
    /// "waiting for the server's commit" from "waiting for its reveal", but the state machine
    /// does.
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
    /// Returning rather than throwing is deliberate: every failure already reaches the UI as a
    /// ``Phase/failed(_:)`` event, and a caller that also had to catch would have two places to
    /// render the same message, one of which ends up stale.
    public func connect(to target: Target, timeout: TimeInterval = 10) async {
        guard let generation = beginConnecting() else {
            emit(.phase(.failed(Failure.busy.errorDescription ?? "busy")))
            return
        }
        emit(.phase(.connecting))

        let pinned: Data? = {
            if case .discovered(let host) = target { return pins.pin(for: host.id) }
            if case .relay(let hostID, _, _) = target { return pins.pin(for: hostID) }
            // Looked up and *not* insisted on: a first pairing has no pin by definition, and
            // the pin is used when there is one. What is skipped is only the refusal, and the
            // handshake below still checks a stored pin if it finds one.
            if case .relayPairing(let hostID, _, _) = target { return pins.pin(for: hostID) }
            // A literal address says nothing about *which* Mac is at it, so there is no pin
            // to insist on before the handshake. The post-handshake check below covers it.
            return nil
        }()
        // Recorded for the post-handshake check: the ID the user read off the other machine.
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
                // A relay dial to a Mac this device claims to know, with nothing in the pin
                // store to back the claim, is refused here rather than at the far end.
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
                // The same tunnel, without the refusal above. `pinned` is whatever the pin
                // store happens to hold for this ID; see
                // ``Target/relayPairing(hostID:name:entitlement:)``.
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
            // An identity failure says so because it *is* one: `Failure.describe` hands back the
            // app's own wording for a `Failure` and the network's sentence for anything the
            // transport threw.
            fail(Failure.describe(error))
            return
        }

        guard isCurrentAttempt(connection, generation: generation) else {
            connection.cancel()
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

        // 2. Say who we are. `wantsPairing` is advisory: the Mac decides, because only the
        //    Mac knows its own pin store.
        let hostID = target.hostID
        let knowsHost = hostID.map { pins.pin(for: $0) != nil } ?? false
        connection.send(.clientHello, ClientHello(
            clientID: clientID,
            clientName: clientName,
            protocolVersion: ProtocolInfo.version,
            wantsPairing: !knowsHost,
            // Declared on every connection, because what it buys is the *Mac's* restraint: a
            // picture it sends to a client that has not said this arrives at one that cannot
            // read it, and the pieces land in that client's picture lane.
            supportsClipboardImages: true,
            supportsTextFocus: true,
            resumeSource: knowsHost ? resumeSource : nil
        ))

        lock.withLock {
            state = .awaitingServerHello
            _phase = .handshaking
        }
        emit(.phase(.handshaking))
        coalescer.start()
    }

    /// Opens the relay's tunnel to a Mac and connects to it through the far end.
    ///
    /// One implementation for both relay targets: the only thing that differs between them is the
    /// pin they arrive with.
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

    /// Distinguishes an obsolete async continuation from a real network failure. It carries no
    /// user-facing text.
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

        // The pin is checked here, after the handshake, because until `serverHello` arrived there was
        // no way to know *which* Mac this is, and a pin is only meaningful next to the identity it
        // belongs to. Nothing an impostor could use has been sent: a role byte, a hello carrying no
        // secret, and our client certificate, which is public.
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

    /// The user's verdict on the six digits. The Mac shows the same code, and comparing them is
    /// what authorises this device: there is no certificate authority behind any of this.
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

        // A video connection is authorized by an *authenticated* control session for the same
        // peer key, so it can only be opened once the handshake above has finished.
        if lock.withLock({ usesRelayedSingleStream }) {
            emit(.video(.connecting))
            // The relay's video transport is wanted, but not yet: see ``wantsVideoDatagrams``
            // for why the request waits for the Mac's description of the stream.
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
            fail(payload?.message ?? "The Mac reported an error.")

        case .clipboardContent:
            handleClipboardContent(frame)

        case .textFocus:
            // Advisory, like a notice: a payload this build cannot read costs the keyboard, not
            // the connection.
            if let focus = try? MessageCodec.decode(TextFocus.self, from: frame.payload) {
                emit(.textFocus(focus))
            }

        case .terminalEvent:
            if let event = try? MessageCodec.decode(TerminalEvent.self, from: frame.payload) {
                emit(.terminal(event))
            } else {
                sessionLog.error("could not decode a terminal event, so it is being dropped")
            }

        // The clipboard's chunks, before the picture's. Both arrive as the same frame kind on this
        // one connection, so which lane a chunk belongs to is the kind byte inside it, and the
        // order of these two cases is what makes it matter: without the guard the clipboard's
        // pieces would be fed to the picture's assembler.
        case .videoChunk where VideoChunk.innerKind(of: frame) == .clipboardContent:
            handleClipboardChunk(frame)

        case .videoConfig, .videoFrame, .videoChunk, .audioConfig, .audioFrame:
            // Everything this connection delivers is the control lane, including whole frames
            // when the session is a relayed one and the Mac has not granted a datagram lane.
            handleVideoFrame(frame, from: .control)

        case .videoKey:
            handleVideoKey(frame)

        default:
            sessionLog.notice("ignoring unexpected \(String(describing: frame.kind), privacy: .public) on a ready session")
        }
    }

    /// Sends a command, subject to the coalescing rules in ``CommandCoalescer``.
    ///
    /// The only path input takes: nothing in the UI sends directly, so the rule that a 120 Hz
    /// touch stream becomes a 60 Hz command stream, and that a `mouseUp` is never dropped even
    /// when the queue is saturated, holds in one place.
    public func send(_ command: RemoteCommand) {
        guard isReady else { return }
        // The reconnect has to know which way the picture's switch was asked for, or a paused
        // client would dial a socket that makes the Mac start capturing again. Recorded here
        // rather than at the call site so the two can never be sent apart.
        if case .setVideoEnabled(let enabled) = command { notePictureRequested(enabled) }
        coalescer.enqueue(command)
    }

    /// Records that the client asked for a picture, or for silence.
    ///
    /// A resume needs a socket to travel on: the Mac answers this command on the control channel,
    /// so a resume for a session whose video socket died during the pause reaches the Mac and
    /// changes nothing unless one is opened here.
    private func notePictureRequested(_ wanted: Bool) {
        lock.withLock { wantsPicture = wanted }
        if wanted { openVideoIfNeeded() }
    }

    /// Switches what the Mac is capturing. Sent as an ordinary command so it rides the same
    /// ordered channel as input, and marked critical so it survives a saturated queue.
    public func selectCaptureSource(_ source: CaptureSource) {
        send(.setCaptureSource(source))
    }

    /// Sends a terminal request directly on the authenticated control stream. Unlike pointer
    /// moves, terminal bytes must never be coalesced or reordered.
    public func sendTerminal(_ request: TerminalRequest) {
        guard isReady else { return }
        connection()?.send(.terminalRequest, request)
    }

    /// Puts a picture on the Mac's pasteboard.
    ///
    /// The picture is JSON inside an ordinary ``RemoteCommand``, and anything larger than one control
    /// message is split by ``ClipboardTransfer`` and put back by the Mac's command handler.
    ///
    /// Sent on the control channel rather than through the coalescer, which is where terminal bytes
    /// go and for the same reason: this is not a gesture. The transport keeps the frames in the
    /// order they were given to it, so a picture cannot be overtaken by the keystrokes typed after
    /// it.
    ///
    /// - Returns: `false` for a picture over the limit both ends carry, which nothing is sent for.
    ///   The caller is expected to have refused it in front of the user already.
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

    /// How often a control ping goes out.
    ///
    /// The figure is shown to someone watching it while they drag something, so a reading taken
    /// seconds apart describes a moment that has already passed. A ping is one small frame and the
    /// control channel is otherwise idle, so asking often costs nothing.
    private static let pingInterval: Duration = .seconds(1)

    /// How long a round trip stays in the reported figure.
    ///
    /// A duration rather than a count: a count of samples has no length anybody can state, and it
    /// re-centres on every sample. Ten seconds is long enough that one bad round trip does not own it.
    private static let latencyWindow: TimeInterval = 10

    /// How many probe attempts go by between two asks at the relay for the peer's address.
    ///
    /// Twelve, which is one re-ask per three seconds during the fast phase and one per minute once
    /// the probing has slowed down, because the attempt counter is what both cadences are counted
    /// in.
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

    /// Fails the session unless the Mac answers within a few round trips.
    ///
    /// For the moments a session can look healthy with nothing under it: the phone's network has
    /// just changed, or the app has just come back from being suspended. The silence watchdog
    /// would get there too, but only after ten seconds of a frozen picture.
    ///
    /// The wait is scaled to the measured round trip: a Mac on the same Wi-Fi answers in
    /// milliseconds, and making it wait out a figure sized for the relay from abroad is most of the
    /// time a return to the app spends on "Reconnecting".
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

    /// Four round trips and a little, between 0.4 and 1.5 seconds. Unmeasured is treated as slow.
    static func answerGrace(roundTripMilliseconds: Double?) -> TimeInterval {
        guard let roundTripMilliseconds else { return 1.0 }
        return min(1.5, max(0.4, roundTripMilliseconds * 4 / 1000 + 0.2))
    }

    /// The middle of the last few round trips, rather than the one that just came back.
    ///
    /// A single ping is one instant on a link that is also carrying video the other way, so
    /// reporting it raw makes the number flicker. A median rather than a mean, deliberately: the
    /// interesting samples are the outliers, a ping that caught a stall, and a mean would let one of
    /// them drag the figure up while the connection is fine.
    private func reportLatency(for frame: Frame) {
        let now = DispatchTime.now()
        let monotonic = Self.monotonicNow()

        let reported = lock.withLock { () -> Double? in
            // A pong is the only thing that proves the control channel is working, and the
            // fallback asks that question before it moves the session's whole picture onto this
            // channel. Answered here because this is where a pong is known to have arrived.
            lastControlReplyAt = monotonic

            // Matched by the number the ping carried, so a reply that arrives after the next ping
            // has gone out is measured against the question it answers. An empty pong is a Mac that
            // does not echo the number.
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
    ///
    /// Called when a session becomes ready, when a client that had asked for no picture asks for one
    /// again, and by the reconnect whenever a video socket closes. The guard below makes repeating
    /// it harmless.
    public func openVideoIfNeeded() {
        lock.lock()
        let alreadyOpen = video != nil
        // A relayed session has no second socket to open: its control connection *is* its video
        // connection, spliced through the relay, and the loopback this would dial is a one-shot
        // listener that has already been consumed. Dialling it again fails, and the failure arrives
        // as "the video connection ended" on a session that is streaming well. See
        // ``usesRelayedSingleStream``.
        guard !alreadyOpen, !usesRelayedSingleStream, wantsPicture, state == .ready,
              let serverKey = _serverKey,
              let hello = _serverHello, let endpoint = control?.remoteEndpoint
        else {
            lock.unlock()
            return
        }
        // An attempt made now is the attempt the ladder was waiting to make, so the wait goes with
        // it. The rung itself is not given back: a socket that opens and dies again is a failure
        // the ladder has to count.
        let pending = videoReconnectTask
        videoReconnectTask = nil
        let connection = ClientConnection(label: "pl.dmq.peering.client.video")
        video = connection
        lock.unlock()
        pending?.cancel()

        // The dedicated video connection, which is the lane the fallback is a fallback *from*.
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
            // A cancellation is our own doing, either the session is over or the socket was
            // replaced, and reporting it would put "video connection ended" on screen after a
            // deliberate disconnect.
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
                // Now that the Mac's identity is known, the pin is enforced *in* the TLS
                // verify block on this socket too, not merely checked afterwards.
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
                  // Asked again after the handshake, because a pause can arrive during one. The role
                  // byte below is what makes the Mac attach and start capturing, so a socket that
                  // sends it for a client that has just asked for no picture spends exactly the
                  // battery the pause was asked for. Before the byte this is not yet a video
                  // connection to the Mac, so dropping it costs nothing.
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

    /// Arms the next attempt at the video socket, if there is one left to make.
    ///
    /// Called when a video socket that was carrying the picture closes for a reason that was not our
    /// own. Everything this must refuse is in the guard: a session that has ended or moved on, one
    /// that is still connecting, a relayed session, which has no second socket to dial, and a client
    /// that has asked the Mac for no picture at all.
    ///
    /// The task carries the generation it was armed under and re-reads it after the wait, as
    /// everything resumed from an `await` in this file does.
    private func scheduleVideoReconnect(generation: UInt64) {
        lock.lock()
        // `video == nil` is in here because a socket replaced between the close and this call has
        // nothing to dial for, and a rung spent refusing to dial it is a rung the next real failure
        // does not get.
        guard videoReconnectTask == nil, video == nil, state == .ready, wantsPicture,
              !usesRelayedSingleStream
        else {
            lock.unlock()
            return
        }
        guard let delay = videoReconnectLadder.next() else {
            lock.unlock()
            // Said out loud once, because the alternative is a frozen frame. The session itself
            // stays up: the shells, the clipboard and the assertion that keeps the Mac awake all
            // still work on it.
            emit(.video(.ended("The video channel did not come back.")))
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

    /// Opens the relay's video datagram lane and asks the Mac for the key that opens it.
    ///
    /// Called once the Mac has described the stream, and only on a session that wants the lane.
    /// See ``wantsVideoDatagrams``.
    ///
    /// The bind goes first, and that ordering is the whole reason this is not one call: the relay
    /// forwards nothing to an address it has not been told about, and it is told by a datagram
    /// consisting of this end's token and nothing else.
    private func startVideoDatagrams() {
        lock.lock()
        guard wantsVideoDatagrams, videoDatagrams == nil, let relay = relaySession else {
            lock.unlock()
            return
        }
        let socket: VideoDatagramSocket
        do {
            socket = try VideoDatagramSocket(
                host: relay.videoHost,
                port: relay.videoPort,
                token: relay.videoToken,
                label: "pl.dmq.peering.client.video.datagrams"
            )
        } catch {
            // Not fatal, and not silent either: without this socket the session still works, with the
            // picture back on the stream the control channel shares.
            //
            // The wish is dropped rather than retried: the cause, an allocation whose token or port
            // is not what the wire contract fixes them at, would be the same next time.
            wantsVideoDatagrams = false
            lock.unlock()
            sessionLog.error("could not open the relay's video datagram socket: \(String(describing: error), privacy: .public)")
            emit(.note("Could not open the relay's video path; the picture will share the control channel."))
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
        // The request carries nothing: the question is whether this session may use the relay's
        // datagram path, and both ends can already see everything needed to answer that.
        connection()?.send(Frame(kind: .videoKeyRequest))
    }

    /// Retires only the failed video lane. The control session remains usable and its chunked
    /// transport is the fallback, but work whose only purpose was this socket must not outlive it.
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

    /// The Mac's answer to ``MessageKind/videoKeyRequest``: the session's video secret.
    ///
    /// Only accepted once the socket exists, because a key with nowhere to receive would sit in the
    /// session looking like a working lane. A Mac that does not answer is a Mac still sending the
    /// picture down the relay's control stream.
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

    /// Asks the relay where the Mac is, and then tries to open a path straight to it.
    ///
    /// Silent on every failure, which is the design rather than an omission: a session that cannot
    /// discover its peer, or whose probes never arrive, is a session on the relay, which is the
    /// ordinary case. Nothing here earns a sentence on screen until it works.
    private func beginDirectPath(secret: Data) {
        guard let pair = lock.withLock({ () -> (VideoDatagramSocket, RelaySession)? in
            guard let socket = videoDatagrams, let relay = relaySession else { return nil }
            return (socket, relay)
        }) else { return }
        let (socket, relay) = pair

        // Built once, here, and kept in the session: see ``videoSealer`` for why there can only
        // ever be one of these for a direction.
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

            // Quick while there is any prospect of it working, then slow for the rest of the session:
            // the fast phase gets a session onto the direct path within a beat of opening, and the
            // slow one recovers a path a NAT mapping expiry took away, for the price of one small
            // datagram every few seconds. It never stops, because a mapping that quietly expires
            // never stops either.
            //
            // Each probe is sealed afresh: the counter is the AEAD nonce and the Mac's replay window
            // is doing its job, so a probe reused byte for byte would be discarded from the second
            // one onward.
            //
            // Discovery is repeated on the same cadence, because "no address yet" is the *ordinary*
            // first answer, and re-asking is also what re-opens a path whose address moved.
            var attempt = 0
            while !Task.isCancelled {
                if attempt % Self.rediscoverEvery == 0 {
                    if let address = try? await RelaySignallingConnection.discoverPeer(
                        at: ProtocolInfo.relaySignallingURL,
                        videoToken: relay.videoToken
                    ) {
                        // Not fatal, but *said*: an address nothing can parse would otherwise go
                        // unnoticed for the whole session. The next discovery replaces it, and until
                        // then ``sendDirect`` does nothing rather than sending to the relay.
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

    /// Measures the lane the picture is on, once a second, for as long as it exists.
    ///
    /// This is the number worth showing, and the control lane's is not: the control connection goes
    /// through the relay in *every* session, punched or not, so its round trip is the relay's even
    /// when the picture is travelling straight between the two ends. This measures the datagrams' own
    /// path.
    ///
    /// It seals through ``sealOnVideoLane(kind:payload:)``: a second sealer would repeat nonces.
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

    /// Seals one message onto the datagram lane, through the session's single sealer.
    ///
    /// The only way anything seals on this lane: the counter inside is the AEAD nonce, so a second
    /// sealer would encrypt under the same key with nonces that had already been used.
    private func sealOnVideoLane(kind: MessageKind, payload: Data) -> [Data] {
        lock.withLock {
            guard var sealer = videoSealer else { return [] }
            defer { videoSealer = sealer }
            return sealer.seal(kind: kind, payload: payload)
        }
    }

    /// Times a lane ping's reply against the ping it answers.
    ///
    /// Matched by number, like the control lane's: a reply that crossed the next ping is measured
    /// against the question it answers, not against the newest one.
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

    /// One datagram from the relay, opened and fed into the same path a whole frame takes.
    ///
    /// There is one decoder and one renderer in this app, and both are downstream of
    /// ``handleVideoFrame(_:from:)``. What comes out of the opener is the frame the Mac cut up, never
    /// a chunk, which is why nothing here reassembles anything.
    ///
    /// Reports a change of path, once per change and not once per datagram: the picture arrives
    /// thousands of times a minute, and the only fact worth passing on is which way it is coming,
    /// which changes at most twice in a session. A note goes with the change *to* the direct path
    /// and not with the change back, because falling back to the relay is the ordinary case.
    private func noteDatagramPath(_ source: VideoDatagramSocket.Source) {
        var path: DatagramPath = .relay
        if case .peer(let host, let port) = source {
            path = .direct
            // The address the Mac is actually answering from: a NAT that moved mid-session is the
            // ordinary case this design is built around, and this is the end that finds out.
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
    ///
    /// Deduplicated for the same reason ``noteDatagramPath`` is: the probing loop runs it over and
    /// over, and a state emitted on every pass is one whose observer cannot tell a change from a
    /// repeat.
    private func reportDirectPath(_ outcome: DirectPath) {
        let changed = lock.withLock { () -> Bool in
            // A path that is open is not closed by a later look-up. The probing loop re-asks the relay
            // where the Mac is every twelve attempts, so a mapping which expired can be replaced, and
            // each of those asks would otherwise *downgrade* a path that is demonstrably carrying the
            // picture. The ask still happens; only the announcement is suppressed.
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
            // A probe has done its whole job by opening: it proved the datagram came from the peer
            // rather than from anyone who can write a source address into a packet, and the address
            // it arrived from is now what the Mac sends to. There is nothing in it to render.
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
            // Logged at picture rate this would bury the log that explains it, so the first is
            // reported and the rest are summarised as they accumulate.
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

    /// One piece of a clipboard payload, from the control channel, where a malformed piece costs the
    /// payload and nothing else.
    ///
    /// `transport` is not decoration: a picture arriving on the transport the session prefers while
    /// the fallback is in force is the only evidence that the path works again. See
    /// ``VideoFallbackPolicy/notePrimaryPicture()``.
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

    /// A whole clipboard payload, however it arrived.
    ///
    /// Decoded leniently, like a notice and unlike a command, which is also the compatibility rule:
    /// a Mac newer than this build sends a picture, this build reads no picture out of it, and the
    /// user is told nothing rather than disconnected.
    private func handleClipboardContent(_ frame: Frame) {
        guard let payload = try? MessageCodec.decode(ClipboardPayload.self, from: frame.payload) else {
            sessionLog.error("could not decode a clipboard payload")
            return
        }
        emit(.clipboard(payload))
    }

    private func handleVideoFrame(_ frame: Frame, from transport: VideoTransport) {
        // Chunked payloads are what the fallback looks like on the wire, and they are put back
        // together into exactly the frame they were cut from. One level only: a chunk of a
        // chunk is refused by the reassembler rather than followed.
        if frame.kind == .videoChunk {
            let reassembled = lock.withLock { () -> Frame? in
                do {
                    return try videoChunks.ingest(frame)
                } catch {
                    // Dropped, not fatal: the next frame starts the assembly over from nothing.
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
            // The picture is back, which is the only thing that counts as a recovery: a socket that
            // connected and said nothing is the failure the ladder exists for, so this is deliberately
            // not cleared where the connection opens.
            //
            // From the preferred lane only: a picture over the control channel says the session is
            // being served, not that the socket the ladder exists for has come back.
            if transport == .primary {
                lock.withLock { videoReconnectLadder.reset() }
            }
            emit(.video(.config(config)))
            // A described stream is what the datagram lane waits for: the description has just
            // arrived over the control channel, so the Mac is already streaming and the lane has
            // something to carry. See ``wantsVideoDatagrams``.
            startVideoDatagrams()

        case .videoFrame:
            note(pictureOn: transport)
            do {
                emit(.video(.frame(try EncodedVideoFrame(decoding: frame.payload))))
            } catch {
                // Dropped rather than fatal: the next keyframe restores the stream.
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

    /// Watches the picture for the one failure neither end otherwise sees.
    ///
    /// A blocked video transport looks from both sides exactly like a working session: the control
    /// channel is up, the Mac answers, and no picture comes. No message in the protocol reports it,
    /// because nothing is missing, the frames are being produced and are simply not arriving. The
    /// rules are in ``VideoFallbackPolicy``; what is here is the clock and the two observations it
    /// runs on.
    private func startVideoWatch() {
        lock.lock()
        // The moment the session became ready is also the moment the first picture is measured
        // from, and that *is* the session-start probe: three seconds of a ready session with a
        // healthy control channel and nothing arriving is the answer, and no extra packet asks it.
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
                // Every second tick is every second: fast enough to read off a screen while a
                // session is running, slow enough not to redraw four numbers sixty times a second.
                ticks += 1
                if ticks % 2 == 0 { self.reportDatagramCounts() }
            }
        }
        videoWatchTask = task
        lock.unlock()
    }

    /// Forgets the fallback's state and hands back the watch to cancel.
    ///
    /// Call with `lock` held, both callers are teardown paths that already have it, and cancel the
    /// returned task after releasing it. `NSLock` is not recursive, so a version of this that took
    /// the lock itself would deadlock.
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
        // And so does the count of attempts the picture has cost: a new session starts with a whole
        // ladder. The armed wait, if there is one, is cancelled by the teardown paths, which have
        // already been handed it.
        videoReconnectLadder.reset()
        // A new session starts wanting a picture. Left standing, a session that had been paused and
        // then reused would open no video socket for the whole of its second life.
        wantsPicture = true
        // The datagram lane's state is the same kind of thing: a replay window and a partial picture
        // describe a link, and both belong to the session that opened it.
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

    /// Ends a session the network has stopped carrying without saying so.
    ///
    /// The case this exists for: the phone changes network, and the path under the control
    /// connection goes away. Nothing fails, not the socket, which was never told, and not any layer
    /// above it, which is waiting for an error. The picture stays on its last decoded frame.
    ///
    /// Turning the absence of a pong into a failure is what the reconnect ladder is waiting for. A
    /// session that recovers inside the window is left alone, because a network handover is a few
    /// seconds of silence that often resolves itself.
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
            // A request rather than an instruction: the host will not move a picture it has not been
            // producing, because a Mac sitting on a still screen cannot tell a blocked path from
            // nothing having changed either. That is also why the ask is repeated on its own schedule,
            // see ``VideoFallbackPolicy``, while what the *screen* is told happens once.
            connection()?.send(.videoTransport, VideoTransportRequest(
                transport: .control,
                reason: "no picture for \(Int(VideoFallbackPolicy.silenceBeforeFallback))s "
                    + "on a control channel that is answering"
            ))
            // The counters ride with the note: a lane that failed is only explicable with the numbers
            // as they were *when* it failed, and settings cannot be opened while a session runs, so a
            // live-only readout would be unreachable exactly here.
            announce(.control, note: "No video is arriving. Asking the Mac to send the picture over the control channel. Datagram lane: \(datagramCounts.summary).")

        case .usePrimaryTransport:
            connection()?.send(.videoTransport, VideoTransportRequest(
                transport: .primary,
                reason: "video is arriving again on the transport it prefers"
            ))
            announce(.primary, note: "Video is arriving again on the faster path. Datagram lane: \(datagramCounts.summary).")
        }
    }

    /// Hands the lane's counters to whoever is watching.
    ///
    /// Silent until there is a lane: a session on the LAN or on the relay's control channel has no
    /// datagram socket, and reporting zeros would read as a lane that is present and idle rather than
    /// one that does not exist.
    private func reportDatagramCounts() {
        guard lock.withLock({ videoDatagrams != nil }) else { return }
        emit(.datagramCounts(datagramCounts))
    }

    /// Says which lane the picture is on, the first time it is on it.
    ///
    /// Once per change rather than once per decision, because a request that produced no picture is
    /// repeated: the ask is a packet, but the note is something a person reads.
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

    /// A picture arrived, on one lane or the other.
    private func note(pictureOn transport: VideoTransport) {
        lock.withLock {
            lastPictureAt = Self.monotonicNow()
            if transport == .primary { fallbackPolicy.notePrimaryPicture() }
        }
    }

    /// Monotonic seconds, for the interval arithmetic above.
    ///
    /// `DispatchTime` rather than `Date`: these are intervals, and a device that syncs its
    /// clock mid-session must not be able to look like three seconds of silence.
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

    /// Ends the session, deliberately. The pin survives; only the sockets go.
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
        // The first failure is the one that counts, and nothing here may contradict it. A connection
        // that fails is reported twice, once by the transport's own close handler and once by the
        // `catch` in `connect` that was waiting on it, so without this guard the property and the
        // event stream could hold two different sentences about the same moment.
        //
        // Returning here rather than after the teardown below is deliberate: a second `fail` has
        // nothing left to tear down.
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
