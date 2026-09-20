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

    /// What the relay's datagram lane has carried so far.
    ///
    /// Public because the session log prints it and the log outlives the session. The counts are
    /// cumulative for the session rather than a rate: a rate needs a window and a decision about
    /// how long, and the comparison worth making is between two readings of the same counter
    /// minutes apart, which needs no window at all.
    public struct DatagramCounts: Sendable, Equatable {
        /// Everything the socket read, from the relay and from the peer alike.
        public let received: Int
        /// The subset that arrived straight from the peer rather than through the relay. This is
        /// the punched path, and the only one an operator can do nothing about.
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
        ///
        /// Written for the question it answers rather than as a dump: "datagrams arriving and
        /// pictures not" is the sentence that means a lossy path, and it can only be read off
        /// the figures if they are beside each other.
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

    /// What the session tells its owner. Everything is a value, so the UI can apply these
    /// on whatever actor it likes.
    public enum Event: Sendable {
        case phase(Phase)
        case host(ServerHello)
        case catalog(CaptureCatalog)
        case video(VideoEvent)
        /// Round-trip time of a control ping, in milliseconds.
        ///
        /// **Not the picture's round trip.** The control connection goes through the relay in
        /// every session, punched or not, so on a session whose video found a path of its own this
        /// figure is the relay's and describes a path the picture is not taking. It stays because
        /// it is still the truth about the control channel, which is what carries input — but see
        /// ``pathLatency(milliseconds:fromPeer:)`` for the one to show.
        case latency(milliseconds: Double)

        /// Round-trip time on the lane the picture is arriving on, in milliseconds.
        ///
        /// `fromPeer` says which path answered: the one the two ends opened between themselves, or
        /// the relay's datagram lane. The reply carries it because the path is a property of where
        /// the datagram came *from*, not of anything either end decided.
        ///
        /// Absent when there is no datagram lane at all, which is most sessions at their start and
        /// some for their whole life. A reader with no path figure falls back to
        /// ``latency(milliseconds:)``, which is then the honest answer: the picture is on the
        /// control channel, so the control channel's round trip is its round trip.
        case pathLatency(milliseconds: Double, fromPeer: Bool)
        /// What the relay's datagram lane has carried, every couple of seconds while one is open.
        ///
        /// Four numbers because a lane fails in four distinguishable ways and they need
        /// different answers: nothing arriving at all is a network that will not carry it,
        /// datagrams arriving and being refused is this end failing to open them, datagrams
        /// arriving and far too few pictures is a path losing the odd packet, and everything
        /// arriving is a lane with nothing wrong with it.
        case datagramCounts(DatagramCounts)
        /// Diagnostics worth surfacing without failing: a pin that was accepted, a video
        /// channel that connected but has not produced a stream yet.
        case note(String)
        /// A standing condition on the Mac that the user should see, or `nil` when there is
        /// none. Unlike ``note(_:)`` this is not a diagnostic to log: it is a caption for the
        /// picture, and it stays up until the Mac says otherwise.
        case remoteNotice(NoticePayload?)
        /// The host's current clipboard text, delivered after a ``RemoteCommand/requestClipboard``
        /// or pushed when the Mac's pasteboard changes.
        case clipboard(String)
        /// An audio stream event from the video channel.
        case audio(AudioEvent)
        /// A reconnectable shell session event from the authenticated control channel.
        case terminal(TerminalEvent)
        /// The relay's free allowance for this client ID is exhausted for the current period.
        case relayQuotaExceeded
        /// Which way the picture is now arriving, once it has changed from the way it started.
        ///
        /// Sent when the direct path takes over and when it is given up, and only then. A session
        /// begins on the relay and stays there unless a punch succeeds, so "relay" is the state a
        /// session is in until this says otherwise — and the absence of this event means the
        /// ordinary case, not a failure.
        case path(DatagramPath)
        /// What the attempt at a path straight to the Mac has come to. See ``DirectPath``.
        case directPath(DirectPath)
    }

    /// Which way the picture is arriving, as this end observes it.
    ///
    /// Only one of the two directions is observed here and that is enough: this end knows what
    /// arrives, and the Mac decides what to send from what *it* receives. The two agree because they
    /// are watching the same path from opposite ends, and neither has to tell the other what it
    /// decided — which is why a punched path costs no new control messages at all.
    public enum DatagramPath: Sendable, Equatable {
        case relay
        case direct
    }

    /// What the attempt at a path straight to the Mac has come to.
    ///
    /// **The failure cases are the point of this.** Both ends were silent about every way the
    /// direct path can fail, deliberately: a session that cannot find its peer is a session on the
    /// relay, which is what every session was before the direct path existed. That was a reasonable
    /// thing to say and it made the feature unfalsifiable. A user seeing `RELAY` could not tell a
    /// NAT that drops packets from a lookup that never answered, and neither could anyone reading
    /// the logs, which is why this exists: the two are different problems with different fixes and
    /// exactly one sentence distinguishes them.
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
        /// Its own case because it was the bug, and it was invisible for exactly as long as it was
        /// nothing: the relay renders a dual-stack socket's v4-mapped source as `::ffff:a.b.c.d`,
        /// `getaddrinfo` refuses that for an `AF_INET` socket, and both call sites discarded the
        /// error. Every session stayed on the relay and looked like two NATs that would not
        /// cooperate. Folding the mapping away is the fix; this is the sentence that would have
        /// found it in an afternoon.
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
        /// screen and the difference is the whole explanation for why the picture is smaller
        /// than it was. ``VideoTransport`` carries the reasoning.
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
        /// A literal address. What the simulator needs, since Bonjour there is unreliable —
        /// and the honest fallback for a network that blocks multicast.
        case address(host: String, port: UInt16)
        /// A previously paired Mac reached through `peeringd` by its stable device ID.
        ///
        /// `entitlement` is what this device can say about what it has bought: the receipt Apple
        /// signed for the live subscription, the plan it claims, and the relay's own key. See
        /// ``RelayEntitlement``, and ``RelayClientMessage/connectToHost`` for what the relay does
        /// with each of the three.
        case relay(hostID: String, name: String, entitlement: RelayEntitlement)

        /// A Mac this device has never paired with, dialled by an ID the user typed or scanned.
        ///
        /// **A separate case rather than a flag, because the difference is a permission.**
        /// ``relay(hostID:name:entitlement:)`` means "the Mac I know by this ID", and it is
        /// refused outright when no pin is stored for it — a guard worth keeping exactly as it
        /// is, since the only ID a device can be born knowing is one a user gave it. This case
        /// means "a Mac I have never met", and what licenses the dial is that a person read the
        /// ID off the other machine and typed or scanned it. Spelling that as its own case means
        /// no default, no boolean and no call site can arrive here by accident: every switch
        /// over ``Target`` has to say what it does about an unpaired Mac, and the compiler asks.
        ///
        /// What arrives here is an **address, not a credential**. A device ID is not a secret —
        /// the Mac shows it, the relay routes by it, and anyone who can read a QR code can
        /// repeat it. Authorising a connection on one would be authorising it on a string a
        /// stranger can copy. The authentication is still the six digits both screens show and
        /// the two people compare, exactly as they do across a desk; this case removes the
        /// requirement that the two devices can see each other, and nothing else. See
        /// ``PairingPayload`` for why the two codes are different kinds of thing.
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
        /// `nil` for a literal address, which says nothing about *which* Mac is at it.
        var hostID: String? {
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
        case notReady
        case protocolMismatch(client: UInt16, host: UInt16)
        case commitmentMismatch
        case noServerKey
        case pinMismatch(hostID: String)
        /// The Mac that answered through the relay is not the one whose ID was dialled.
        ///
        /// A routing check, and nothing more. The relay routes by device ID, so a Mac that
        /// reports a different one means the user typed or scanned the wrong Mac's code, or
        /// scanned it badly — a mistake worth catching in the second it takes to appear rather
        /// than leaving them to compare six digits that can never match and conclude the app is
        /// broken. It is deliberately *not* doing any of the authenticating: the ID is a name
        /// the relay and the Mac both know, and only the code comparison covers the case where
        /// the relay itself answers with something it is not.
        case hostIDMismatch(dialled: String, answered: String)
        case unexpected(MessageKind, expected: String)
        case identity(String)

        /// What to say about an error that came from the network rather than from the protocol.
        ///
        /// **The table itself lives in ``NetworkFailureText``**, and this forwards to it. It used
        /// to be the only spelling of the rule, which is how the transport came to have a second
        /// one: `error.localizedDescription`, which for an `NWError` is not a sentence at all but
        /// the string `Network.NWError error 60`. One table, called from both places that can
        /// fail this way, so the next one cannot leak the raw error again.
        static func describe(_ error: Error) -> String {
            NetworkFailureText.describe(error)
        }

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
    /// The pings in flight, and the window they are measured into.
    ///
    /// Both rules live in ``PingLedger`` and ``LatencyWindow`` so they can be driven by a test:
    /// every interesting case in them is about *timing*, and timing is the one thing a test
    /// cannot wait for.
    private var pingLedger = PingLedger()
    private var latency = LatencyWindow(length: ClientSession.latencyWindow)

    /// The video transport watchdog: the rules, and the three things it watches. See
    /// ``evaluateVideoTransport()``.
    private var videoWatchTask: Task<Void, Never>?
    private var fallbackPolicy = VideoFallbackPolicy()
    /// When a picture last arrived, on either lane. The fallback's whole input.
    private var lastPictureAt: TimeInterval?
    /// When the control channel last answered anything.
    private var lastControlReplyAt: TimeInterval?
    /// Chunks in from the control channel, pictures out. Only ever fed from the control lane:
    /// the preferred transport carries whole frames, which need no reassembly.
    private var videoChunks = VideoChunkReassembler()
    private var _videoFallbackEnabled = true
    /// The lane the UI has already been told about, so a repeated request is not a repeated note.
    private var announcedTransport: VideoTransport = .primary

    /// The relay's allocation for this session, when there is one. Its video host and port are
    /// where the Mac's datagrams come from, and its token is what this end binds with.
    private var relaySession: RelaySession?
    /// Whether this session wants the relay's datagram path, and has not opened it yet.
    ///
    /// **A flag rather than the act itself, and the delay is the point.** The lane is opened
    /// when the Mac's description of the stream has arrived, not when the session becomes
    /// ready — because the description is what the Mac sends it on. Opening before that puts
    /// a race between the Mac's first config and the key that opens it: the Mac grants the
    /// lane before its capture has produced anything to describe, sends the description down
    /// the new lane the moment it has one, and if that datagram arrives before the grant does
    /// the client cannot read it and the picture starts black. Waiting for a description that
    /// travelled the control channel removes the race rather than losing a coin toss to it.
    private var wantsVideoDatagrams = false
    /// The socket the Mac's sealed video datagrams arrive on. Nil on every session that is
    /// not a relayed one, and nil until the lane is opened.
    private var videoDatagrams: VideoDatagramSocket?
    /// The task that asks the relay where the Mac is and then keeps probing it.
    ///
    /// Held so it can be cancelled with the socket: a probe that outlives its session is a datagram
    /// sent to an address that has moved on, and a task that outlives it is a leak.
    private var directPathTask: Task<Void, Never>?
    /// The last path reported to the owner, so a change is reported once rather than per datagram.
    ///
    /// Seeded with `.relay` rather than left optional: every session starts on the relay, so the
    /// first datagram to arrive is not news, and treating it as such would put a message on screen
    /// at the start of every session.
    private var reportedPath: DatagramPath = .relay

    /// The last thing the direct-path attempt reported, so the same state is not emitted twice.
    private var reportedDirectPath: DirectPath = .notTried
    /// The other half of that lane: the key, the replay window and the reassembler. Set when
    /// the Mac's answer to ``MessageKind/videoKeyRequest`` arrives, and nil until then — a
    /// datagram that arrives before it cannot be opened, which is why the Mac's first few
    /// frames after a grant are wasted rather than late.
    private var videoOpener: VideoDatagramOpener?

    /// Seals what this end puts on the datagram lane: the probes, and the lane's own pings.
    ///
    /// **One instance for the whole session, and that is a safety property rather than tidiness.**
    /// The sealer's counter *is* the ChaChaPoly nonce, and the nonce is the whole of its entropy:
    /// two sealers built from one secret for one direction would encrypt under the same key with
    /// the same nonces, which is the one failure an AEAD does not survive. Everything that seals
    /// onto this lane therefore goes through this one value, under the session's lock.
    private var videoSealer: VideoDatagramSealer?

    /// The pings in flight on the datagram lane, and the window they are measured into.
    ///
    /// Separate from the control lane's, because they measure different paths and a session can
    /// have both at once: the control connection goes through the relay in every session, punched
    /// or not, so its round trip is not the one the picture is travelling.
    private var pathPingLedger = PingLedger()
    private var pathLatency = LatencyWindow(length: ClientSession.latencyWindow)
    private var lanePingTask: Task<Void, Never>?

    /// How many datagrams did not authenticate, and whether the user has been told.
    ///
    /// Counted rather than merely logged because the interesting case is the *rate*: one is a
    /// corrupted packet, and one per picture is two ends that are not speaking the same key.
    private var datagramFailures = 0
    private var reportedDatagramFailure = false
    /// Pictures that arrived whole from the peer, and the number that matters most.
    ///
    /// A picture is cut into roughly a hundred datagrams, so a frame completes only if *every*
    /// one of them lands. A lane losing one datagram in a hundred therefore delivers about a
    /// third of its pictures, and one losing one in twenty delivers almost none, while the
    /// datagram counters beside this one climb the whole time and look healthy. Datagrams
    /// arriving and pictures arriving are different facts, and only the pair of them says which
    /// end of that trade a session is on.
    private var picturesFromPeer = 0

    /// Whether this session's video could be travelling a path that a network can block.
    ///
    /// Set by the caller from the *kind* of connection, because that is knowledge the session
    /// does not have: a Mac found over Bonjour is on this network, where a missing picture is
    /// a different problem with a different answer, while a relay session and a typed-in
    /// address both cross networks nobody here controls. Moving a local session onto the
    /// control channel would trade a fast picture for a slow one to solve a problem the local
    /// network does not have.
    public var videoFallbackEnabled: Bool {
        get { lock.withLock { _videoFallbackEnabled } }
        set { lock.withLock { _videoFallbackEnabled = newValue } }
    }

    /// The device ID a first pairing was dialled by, so the answer can be checked against it.
    ///
    /// Set by ``connect(to:timeout:)`` for every attempt — `nil` for the targets where the ID
    /// is not the user's to give — and read once, when the Mac says who it is.
    private var pairingHostID: String?

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
            if case .relay(let hostID, _, _) = target { return pins.pin(for: hostID) }
            // Looked up and *not* insisted on. A first pairing has no pin by definition, and
            // the requirement the target carries is that the user asked for this Mac; the pin
            // is used when there is one, which is what happens when the same ID is dialled
            // again by someone who already paired with it. What is skipped is only the
            // refusal, and the handshake below still checks a stored pin if it finds one.
            if case .relayPairing(let hostID, _, _) = target { return pins.pin(for: hostID) }
            // A literal address says nothing about *which* Mac is at it, so there is no pin
            // to insist on before the handshake. The post-handshake check below covers it.
            return nil
        }()
        // Recorded for the post-handshake check, which is the one thing a first pairing
        // cannot do without: the ID the user read off the other machine.
        lock.withLock { pairingHostID = target.isFirstPairing ? target.hostID : nil }

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
            case .relay(let hostID, _, let entitlement):
                // The guard this case has always had, unchanged. A relay dial to a Mac this
                // device claims to know, with nothing in the pin store to back the claim, is
                // refused here rather than at the far end.
                guard let pin = pins.pin(for: hostID) else {
                    throw Failure.pinMismatch(hostID: hostID)
                }
                try await openRelayTunnel(
                    to: connection,
                    hostID: hostID,
                    entitlement: entitlement,
                    pinnedServerKey: pin,
                    timeout: timeout
                )

            case .relayPairing(let hostID, _, let entitlement):
                // The same tunnel, without the refusal above. `pinned` is whatever the pin
                // store happens to hold for this ID — see ``Target/relayPairing(hostID:name:entitlement:)``
                // for what licenses that, and why the ID is not the secret in this exchange.
                try await openRelayTunnel(
                    to: connection,
                    hostID: hostID,
                    entitlement: entitlement,
                    pinnedServerKey: pinned,
                    timeout: timeout
                )
            }
        } catch {
            if let e = error as? RelaySignallingError,
               case .refused(let code, _) = e, code == "quotaExceeded" {
                emit(.relayQuotaExceeded)
            }
            let isRelaySetupFailure = error is RelaySignallingError || error is RelayTunnelError
            let message = (pinned != nil && !isRelaySetupFailure)
                // A pin was in force and TLS refused, which is the one failure worth naming
                // precisely: it is either an impostor or a Mac that was reset.
                ? "The Mac at \(target.displayName) did not present the key this device has pinned for it. If it was reset, forget it here and pair again."
                : Failure.describe(error)
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
        let hostID = target.hostID
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

    /// Opens the relay's tunnel to a Mac and connects to it through the far end.
    ///
    /// One implementation for both relay targets, because the only thing that differs between
    /// them is the pin they arrive with — and it is the pin, not the plumbing, that the two
    /// meanings turn on. Splitting this in two would mean two copies of the ordering below,
    /// which is the part that has to be right.
    private func openRelayTunnel(
        to connection: ClientConnection,
        hostID: String,
        entitlement: RelayEntitlement,
        pinnedServerKey: Data?,
        timeout: TimeInterval
    ) async throws {
        let allocation = try await RelaySignallingConnection.requestSession(
            at: ProtocolInfo.relaySignallingURL,
            hostID: hostID,
            clientID: clientID,
            entitlement: entitlement
        )
        let proxy = RelayControlProxy(session: allocation)
        let endpoint = try await proxy.start()
        lock.withLock {
            relayProxy = proxy
            usesRelayedSingleStream = true
            // Kept because the relay told this end where the Mac's video datagrams
            // will come from and what to bind with, and there is no second chance to
            // ask: the signalling socket is closed the moment the session is returned.
            relaySession = allocation
        }
        try await connection.connect(
            to: endpoint,
            identity: identity,
            pinnedServerKey: pinnedServerKey,
            timeout: timeout
        )
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

        // Before the pin and before the pairing: is this the Mac that was dialled? Checked
        // here rather than at the relay, which routes by ID but answers for whatever holds
        // it. See ``Failure/hostIDMismatch(dialled:answered:)`` for what this is and is not.
        if let dialled = lock.withLock({ pairingHostID }), hello.serverID != dialled {
            fail(Failure.hostIDMismatch(dialled: dialled, answered: hello.serverID).errorDescription ?? "")
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
            //
            // Re-pin now using the server key we already verified over TLS, so the Mac
            // reappears in Trusted Macs after a "Forget" on this side.
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
            // Decoded leniently on purpose. A notice is advisory — the session is healthy and
            // this is only a caption for it — so a payload this build cannot read costs the
            // caption and not the connection.
            let payload = try? MessageCodec.decode(NoticePayload.self, from: frame.payload)
            emit(.remoteNotice(payload))

        case .error:
            let payload = try? MessageCodec.decode(ErrorPayload.self, from: frame.payload)
            fail(payload?.message ?? "The Mac reported an error.")

        case .clipboardContent:
            if let payload = try? MessageCodec.decode(ClipboardPayload.self, from: frame.payload) {
                emit(.clipboard(payload.text))
            }

        case .terminalEvent:
            if let event = try? MessageCodec.decode(TerminalEvent.self, from: frame.payload) {
                emit(.terminal(event))
            }

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

    /// Sends a terminal request directly on the authenticated control stream. Unlike pointer
    /// moves, terminal bytes must never be coalesced or reordered.
    public func sendTerminal(_ request: TerminalRequest) {
        guard isReady else { return }
        connection()?.send(.terminalRequest, request)
    }

    private func sendNow(_ command: RemoteCommand) {
        connection()?.send(command)
    }

    // MARK: - Liveness

    /// How often a control ping goes out.
    ///
    /// One second, where this was five. The figure is shown to someone who is watching it while
    /// they drag something, and a reading taken every five seconds describes a moment that has
    /// already passed by the time it appears — which is most of why it looked like it was
    /// jumping. A ping is one small frame and the control channel is otherwise idle, so the
    /// cost of asking five times as often is nothing.
    private static let pingInterval: Duration = .seconds(1)

    /// How long a round trip stays in the reported figure.
    ///
    /// **A duration rather than a count**, where this used to be five samples. Five samples a
    /// second apart is five seconds and five samples after a stall is eight, so the window the
    /// number was drawn from had no length anybody could state — and it re-centred on every
    /// sample, which is most of what "it jumps" meant. Ten seconds is long enough that one bad
    /// round trip does not own the figure and short enough that the figure still describes now.
    private static let latencyWindow: TimeInterval = 10

    /// How many probe attempts go by between two asks at the relay for the peer's address.
    ///
    /// Twelve, which is one re-ask per three seconds during the fast phase and one per minute once
    /// the probing has slowed down, because the attempt counter is what both cadences are counted
    /// in. Frequent enough to catch a peer whose first datagram was a moment late, rare enough that
    /// a session nobody can punch through is not a session that keeps opening WebSockets.
    static let rediscoverEvery = 12

    private func startPinging() {
        lock.lock()
        guard pingTask == nil else { lock.unlock(); return }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard !Task.isCancelled, let self else { return }
                let ping = self.lock.withLock {
                    self.pingLedger.record(now: DispatchTime.now().uptimeNanoseconds)
                }
                // A ping is small and the control channel is otherwise idle, so the payload costs
                // nothing and is what makes the reply measurable. A Mac that does not echo it
                // answers empty, which the ledger reads as the oldest question still open.
                let payload = (try? MessageCodec.encode(PingPayload(sequence: ping.sequence))) ?? Data()
                self.connection()?.send(Frame(kind: .ping, payload: payload))
            }
        }
        pingTask = task
        lock.unlock()
    }

    /// The middle of the last few round trips, rather than the one that just came back.
    ///
    /// A single ping is one instant on a link that is also carrying video in the other
    /// direction, and it will occasionally catch a moment when something else has the radio.
    /// Reporting it raw is what made the number flicker between readings taken seconds apart:
    /// what a user wants from it is the latency they would see if they asked repeatedly, and
    /// the median of a handful of requests is a better answer to that than any single one.
    ///
    /// A median rather than a mean, deliberately. The interesting samples here are the outliers
    /// — a ping that caught a stall — and a mean would let one of them drag the figure up for
    /// the next five seconds while the connection is fine.
    private func reportLatency(for frame: Frame) {
        let now = DispatchTime.now()
        let monotonic = Self.monotonicNow()

        let reported = lock.withLock { () -> Double? in
            // A pong is the only thing that proves the control channel is working, and the
            // fallback asks that question before it moves the session's whole picture onto
            // this channel. Answered here because this is where a pong is known to have
            // arrived, rather than by a second timer inferring it from the latency figure.
            lastControlReplyAt = monotonic

            // Matched by the number the ping carried, so a reply that arrives after the next ping
            // has gone out is measured against the question it answers. An empty pong is a Mac
            // that does not echo the number; the ledger reads that as the oldest question open.
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
        guard !alreadyOpen, state == .ready, let serverKey = _serverKey,
              let hello = _serverHello, let endpoint = control?.remoteEndpoint
        else {
            lock.unlock()
            return
        }
        let connection = ClientConnection(label: "pl.dmq.peering.client.video")
        video = connection
        lock.unlock()

        // The dedicated video connection, which is the lane the fallback is a fallback *from*.
        connection.onFrame = { [weak self] frame in self?.handleVideoFrame(frame, from: .primary) }
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

    /// Opens the relay's video datagram lane and asks the Mac for the key that opens it.
    ///
    /// Called once the Mac has described the stream, and only on a session that wants the
    /// lane — see ``wantsVideoDatagrams``.
    ///
    /// **The bind goes first, and that ordering is the whole reason this is not one call.**
    /// The relay forwards nothing to an address it has not been told about, and it is told by
    /// a datagram consisting of this end's token and nothing else. So the socket binds the
    /// moment it exists, the request for the key follows it over the control channel a round
    /// trip later, and by the time the Mac's first sealed datagram can reach the relay the
    /// address it is meant for is registered. The reverse order would spend the first frames
    /// of every session on a relay that had nowhere to send them.
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
            // Not fatal, and not silent either: without this socket the session still works,
            // with the picture back on the stream the control channel shares.
            //
            // The wish is dropped rather than retried, because this failure has one cause — an
            // allocation whose token or port is not what the wire contract fixes them at — and
            // it will be the same cause on the next stream description as it was on this one.
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
        socket.onFailure = { [weak self] error in
            sessionLog.error("the video datagram socket failed: \(error.localizedDescription, privacy: .public)")
            self?.emit(.note("The relay's video path stopped responding."))
        }
        // The bind and the keepalive that repeats it. A NAT binding that expires is a session
        // that stops receiving video without anything on either end reporting a problem.
        socket.start()

        emit(.note("Remote session open; asking the Mac to send the picture directly."))
        // The request carries nothing: the question is whether this session may use the relay's
        // datagram path, and both ends can already see everything needed to answer that.
        connection()?.send(Frame(kind: .videoKeyRequest))
    }

    /// The Mac's answer to ``MessageKind/videoKeyRequest``: the session's video secret.
    ///
    /// Only accepted once the socket exists, because a key with nowhere to receive is a value
    /// that would sit in the session looking like a working lane. A Mac that does not answer
    /// is a Mac still sending the picture down the relay's control stream, which is what this
    /// session did before there was a datagram path at all.
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
    /// discover its peer, or whose probes never arrive, is a session on the relay — what every
    /// session was before this existed and what most will still be. Nothing here has earned a
    /// sentence on screen until it works.
    private func beginDirectPath(secret: Data) {
        guard let pair = lock.withLock({ () -> (VideoDatagramSocket, RelaySession)? in
            guard let socket = videoDatagrams, let relay = relaySession else { return nil }
            return (socket, relay)
        }) else { return }
        let (socket, relay) = pair

        directPathTask?.cancel()

        // Built once, here, and kept in the session: see ``videoSealer`` for why there can only
        // ever be one of these for a direction.
        let schedule = VideoKeySchedule(secret: secret)
        guard let sealer = try? schedule.sealer(token: relay.videoToken, direction: .clientToHost)
        else { return }
        lock.withLock { videoSealer = sealer }

        startLanePinging(socket)

        directPathTask = Task { [weak self] in

            // Quick while there is any prospect of it working, then slow for the rest of the
            // session. The fast phase is what gets a session onto the direct path within a beat of
            // opening; the slow one is what recovers a path that a NAT mapping expiry took away,
            // for the price of one small datagram every few seconds. It never stops, because the
            // thing it is guarding against — a mapping that quietly expires — never stops either.
            //
            // Each probe is sealed afresh, and that is load-bearing rather than tidy. The counter is
            // the AEAD nonce, and the Mac's replay window is doing its job — so a probe reused byte
            // for byte would be discarded from the second one onward, and the path would never be
            // believed however many were sent.
            //
            // **Discovery is repeated on the same cadence, and that is the change worth naming.**
            // It used to be asked once and the whole attempt abandoned if the answer was no, and
            // "no" is the *ordinary* first answer, because the relay only knows where a peer is
            // once that peer has sent it a datagram, which is a few milliseconds behind the asking.
            // So a session could give up permanently on a peer that was about to introduce itself.
            // Re-asking costs one small datagram every three seconds for the first few of a session
            // and one a minute after that, and it is also what re-opens a path whose address moved.
            var attempt = 0
            while !Task.isCancelled {
                if attempt % Self.rediscoverEvery == 0 {
                    if let address = try? await RelaySignallingConnection.discoverPeer(
                        at: ProtocolInfo.relaySignallingURL,
                        videoToken: relay.videoToken
                    ) {
                        // A failure here is not fatal, but it is *said*, which it was not: the
                        // `try?` that used to be here is how an address nothing could parse went
                        // unnoticed for the whole life of the feature. The next discovery replaces
                        // it, and until then ``sendDirect`` does nothing rather than sending to the
                        // relay.
                        let peer = "\(address.host):\(address.port)"
                        do {
                            try socket.setDirectPeer(host: address.host, port: address.port)
                            self?.reportDirectPath(.probing(peer: peer))
                        } catch {
                            self?.reportDirectPath(.addressUnusable(peer: peer))
                        }
                    } else {
                        self?.reportDirectPath(.noAddress)
                    }
                }

                if let probe = self?.sealOnVideoLane(kind: .directProbe, payload: Data()),
                   !probe.isEmpty {
                    socket.sendDirect(probe) { _ in }
                }
                attempt += 1
                let interval: Duration = attempt <= 12 ? .milliseconds(250) : .seconds(5)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Measures the lane the picture is on, once a second, for as long as it exists.
    ///
    /// **This is the number worth showing, and the control lane's is not.** The control connection
    /// goes through the relay in *every* session, punched or not, so its round trip is the relay's
    /// even when the picture is travelling straight between the two ends — which is where "it is
    /// pretty high" came from. This measures the datagrams' own path, and ``VideoDatagramSocket/send``
    /// sends by whichever of the two is currently the better one, which is the same rule the
    /// picture follows.
    ///
    /// It seals through ``sealOnVideoLane(kind:payload:)`` rather than a sealer of its own. A
    /// second sealer would repeat nonces, and the reply says which path it came back on, so the
    /// figure can be labelled rather than guessed at.
    private func startLanePinging(_ socket: VideoDatagramSocket) {
        lanePingTask?.cancel()
        lanePingTask = Task { [weak self] in
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
    /// Must be the only way anything seals on this lane. The counter inside is the AEAD nonce, so a
    /// second sealer built from the same secret would encrypt under the same key with nonces that
    /// had already been used.
    private func sealOnVideoLane(kind: MessageKind, payload: Data) -> [Data] {
        lock.withLock {
            guard var sealer = videoSealer else { return [] }
            defer { videoSealer = sealer }
            return sealer.seal(kind: kind, payload: payload)
        }
    }

    /// Times a lane ping's reply against the ping it answers.
    ///
    /// Matched by number for the same reason the control lane's is: a reply that crossed the next
    /// ping has to be measured against the question it answers, not against the newest one.
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
    /// ``handleVideoFrame(_:from:)``. What comes out of the opener is the frame the Mac cut
    /// up — never a chunk, which is why nothing here reassembles anything.
    /// Reports a change of path, once per change.
    ///
    /// Once per change and not once per datagram: the picture arrives thousands of times a minute
    /// and the only fact worth passing on is which way it is coming, which changes at most twice in
    /// a session. A note goes with the change *to* the direct path and not with the change back —
    /// falling back to the relay is the ordinary case, and saying so every time a mapping expires
    /// would be an app that appears to keep breaking.
    private func noteDatagramPath(_ source: VideoDatagramSocket.Source) {
        var path: DatagramPath = .relay
        if case .peer(let host, let port) = source {
            path = .direct
            // The address the Mac is actually answering from, which is the one that matters: a
            // NAT that moved mid-session is the ordinary case this design is built around, and
            // this is the end that finds out.
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
    /// Deduplicated for the same reason ``noteDatagramPath`` is: this is driven from the probing
    /// loop, which runs fifty times in the first minute of a session, and a state that is emitted
    /// on every pass is a state whose observer cannot tell a change from a repeat.
    private func reportDirectPath(_ outcome: DirectPath) {
        let changed = lock.withLock { () -> Bool in
            // **A path that is open is not closed by a later look-up.** The probing loop asks the
            // relay where the Mac is every twelve attempts, for the whole session, so that a
            // mapping which expired can be replaced. Every one of those asks announced `probing`,
            // which *downgraded* a path that was demonstrably carrying the picture to "nothing
            // back yet". The log then read as a direct path that kept failing while the transport
            // had not moved in minutes, which is exactly how it was read on a session that never
            // left the punched path once. The ask still happens and the address is still
            // replaced; only the announcement is suppressed.
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
            // and not from anyone who can write a source address into a packet, and the address it
            // arrived from is now what the Mac sends to. There is nothing in it to render, and a
            // real frame has never been seen under this kind.
            guard frame.kind != .directProbe else { return }
            // A lane ping's reply, which is timed here rather than passed on: everything else the
            // opener produces is a piece of the picture, and the renderer would try to read this
            // as one.
            guard frame.kind != .pong else {
                notePathLatency(frame, from: source)
                return
            }
            lock.withLock { picturesFromPeer += 1 }
            handleVideoFrame(frame, from: .primary)

        case .failure(let error):
            // Counted, logged, and never dropped in silence. A datagram that does not
            // authenticate is the only thing that tells "this network is losing video" apart
            // from "these two ends are not speaking the same key", and the second of those
            // has no other symptom at all.
            let (total, firstTime) = lock.withLock { () -> (Int, Bool) in
                datagramFailures += 1
                let first = !reportedDatagramFailure
                reportedDatagramFailure = true
                return (datagramFailures, first)
            }
            // Every failure logged at picture rate would bury the log that explains it, so
            // the first is reported and the rest are summarised as they accumulate.
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

    /// One video-channel frame, from whichever lane delivered it.
    ///
    /// `transport` is not decoration. A picture arriving on the transport the session prefers
    /// while the fallback is in force is the only evidence that the path works again, and it
    /// is what the client's decision to go back is made of — see
    /// ``VideoFallbackPolicy/notePrimaryPicture()``.
    private func handleVideoFrame(_ frame: Frame, from transport: VideoTransport) {
        // Chunked payloads are what the fallback looks like on the wire, and they are put back
        // together into exactly the frame they were cut from. One level only: a chunk of a
        // chunk is refused by the reassembler rather than followed.
        if frame.kind == .videoChunk {
            let reassembled = lock.withLock { () -> Frame? in
                do {
                    return try videoChunks.ingest(frame)
                } catch {
                    // Dropped, not fatal. A picture is worth less than the session, and the
                    // next frame starts the assembly over from nothing.
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
            emit(.video(.config(config)))
            // A described stream is what the datagram lane waits for. See
            // ``wantsVideoDatagrams``: the description has just arrived over the control
            // channel, so the Mac is already streaming and the lane has something to carry.
            startVideoDatagrams()

        case .videoFrame:
            note(pictureOn: transport)
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

        case .audioConfig:
            if let config = try? MessageCodec.decode(AudioStreamConfig.self, from: frame.payload) {
                emit(.audio(.config(config)))
            }

        case .audioFrame:
            if let frame_decoded = try? EncodedAudioFrame(decoding: frame.payload) {
                emit(.audio(.frame(frame_decoded)))
            }

        default:
            break
        }
    }

    // MARK: - Video transport

    /// Watches the picture for the one failure neither end otherwise sees.
    ///
    /// A blocked video transport looks from both sides exactly like a working session: the
    /// control channel is up, the Mac answers, the status is green, and no picture comes. No
    /// message in the protocol reports it, because nothing is missing — the frames are being
    /// produced and are simply not arriving. So the client watches for the absence and says
    /// so, which is the half of the loop the host cannot run. The rules are in
    /// ``VideoFallbackPolicy``; what is here is the clock and the two observations it runs on.
    private func startVideoWatch() {
        lock.lock()
        // The moment the session became ready is also the moment the first picture is
        // measured from, and that *is* the session-start probe: three seconds of a ready
        // session with a healthy control channel and nothing arriving is the answer, and no
        // extra packet is sent to ask the question.
        lastPictureAt = Self.monotonicNow()
        lastControlReplyAt = nil
        fallbackPolicy.reset()
        guard videoWatchTask == nil else { lock.unlock(); return }
        let task = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.evaluateVideoTransport()
                // The counts every second tick, which is every second: fast enough to read them
                // off a screen while a session is running, and slow enough that a screen showing
                // four numbers is not redrawn sixty times a second to show the same four.
                ticks += 1
                if ticks % 2 == 0 { self.reportDatagramCounts() }
            }
        }
        videoWatchTask = task
        lock.unlock()
    }

    /// Forgets the fallback's state and hands back the watch to cancel.
    ///
    /// Call with `lock` held — both callers are teardown paths that already have it — and
    /// cancel the returned task after releasing it. `NSLock` is not recursive, so a version
    /// of this that took the lock itself would deadlock the session on its way out.
    private func stopVideoWatchLocked() -> Task<Void, Never>? {
        let task = videoWatchTask
        videoWatchTask = nil
        fallbackPolicy.reset()
        lastPictureAt = nil
        lastControlReplyAt = nil
        videoChunks = VideoChunkReassembler()
        announcedTransport = .primary
        // The datagram lane's state is the same kind of thing: a replay window and a partial
        // picture describe a link, and both belong to the session that opened it. The socket
        // itself is cancelled by the teardown paths, which have already been handed it.
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
            // A request rather than an instruction, and the host is right to treat it as one:
            // it will not move a picture it has not been producing, because a Mac sitting on a
            // still screen cannot tell a blocked path from nothing having changed either.
            // Which is also why the ask is repeated on its own schedule — see ``VideoFallbackPolicy``
            // — while what the *screen* is told happens once, when the lane actually changes.
            connection()?.send(.videoTransport, VideoTransportRequest(
                transport: .control,
                reason: "no picture for \(Int(VideoFallbackPolicy.silenceBeforeFallback))s "
                    + "on a control channel that is answering"
            ))
            // The counters ride with the note, and that is the point of putting them here rather
            // than only on a diagnostics screen: this sentence is the moment the picture moved,
            // the log is what outlives the session, and a lane that failed is only explicable
            // with the numbers as they were *when* it failed. Settings cannot even be opened
            // while a session runs, so a live-only readout would be unreachable exactly here.
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
    /// Silent until there is a lane: a session on the LAN or on the relay's control channel has
    /// no datagram socket, and reporting zeros for one would read as a lane that is present and
    /// idle rather than one that does not exist.
    private func reportDatagramCounts() {
        guard lock.withLock({ videoDatagrams != nil }) else { return }
        emit(.datagramCounts(datagramCounts))
    }

    /// Says which lane the picture is on, the first time it is on it.
    ///
    /// Once per change rather than once per decision, because a request that produced no
    /// picture is repeated and the client would otherwise fill its own note list with the same
    /// sentence — the ask is a packet, but the note is something a person reads.
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
        let datagrams = self.videoDatagrams
        self.control = nil
        self.video = nil
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
        coalescer.flush()
        video?.cancel()
        datagrams?.cancel()
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
        let datagrams = self.videoDatagrams
        self.video = nil
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
        guard !alreadyFailed else { return }
        sessionLog.error("session failed: \(message, privacy: .public)")
        emit(.phase(.failed(message)))
        // The video socket carries no handshake of its own and is authorized only by this
        // control session, so it dies with it. The datagram lane is the same arrangement one
        // step further out: the relay only forwards it while the session it belongs to lives.
        video?.cancel()
        datagrams?.cancel()
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
