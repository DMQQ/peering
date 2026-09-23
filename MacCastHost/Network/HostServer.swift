import Foundation
import Network
import RemoteCore
import os

private let videoLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")
private let sessionLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

/// Advertises the host over Bonjour and accepts both connection roles.
///
/// One listener serves the control and video channels; the first frame on each connection
/// declares which it is. They are separate TCP connections on purpose — sharing one stream
/// would put a 200 KB keyframe in front of the next mouse move, and control latency is
/// exactly what a user feels.
///
/// All mutable state is confined to ``queue``. Everything crossing out of it does so as a
/// ``HostEvent``.
final class HostServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pl.dmq.peering.host.server")

    private let identity: SelfSignedIdentity
    private let device: DeviceIdentity
    private let pins: PinStore

    /// The TCP port to listen on.
    ///
    /// A parameter rather than the constant this used to read, because a Mac sharing its network
    /// with something else already on 51515 has nowhere to go otherwise. Nothing else has to
    /// know: Bonjour advertises whatever is bound here, so a phone on the same network follows
    /// a custom port with no configuration of its own. Only the manual-address path needs the
    /// number typed, and only the relay bridge needs telling — see ``connectThroughRelay(_:)``.
    private let port: UInt16

    private var listener: NWListener?

    /// Ends sessions whose client has stopped answering, so a dead connection cannot outlive it.
    private var reaper: DispatchSourceTimer?
    private var controlSessions: [HostSession] = []
    private var pendingRelayBridges: [RelayTunnel] = []
    private var activeRelayBridges: [RelayTunnel] = []
    private let terminalManager = TerminalSessionManager()

    /// A relay session's local end, and the allocation the relay gave it.
    ///
    /// The two are kept together because they are only ever known together — the allocation
    /// arrives on the signalling socket and the connection it belongs to is accepted a moment
    /// later — and because the allocation is what a granted datagram lane is built from: the
    /// address the relay wants this Mac's video sent to, and the token that says which session
    /// is sending it. Without it a relayed session has no picture but the one on the control
    /// stream, which is the arrangement the datagram path exists to leave.
    private struct RelayTunnel {
        let id: UUID
        let bridge: RelayControlBridge
        let session: RelaySession
    }

    /// Each video connection is tagged with the client key that authorized it, so it can be
    /// torn down when that client's control session ends.
    private var videoConnections: [(peer: PeerConnection, clientKey: Data)] = []

    private let callbackLock = NSLock()
    private var _onPushNeeded: (@Sendable (String, String) -> Void)?
    private var _onEvent: (@Sendable (HostEvent) -> Void)?
    private var _onCommand: (@Sendable (RemoteCommand) -> Void)?
    private var _onVideoConnection: (@Sendable (PeerConnection) -> Void)?
    private var _onVideoTransport: (@Sendable (Data?, VideoTransportRequest, PeerConnection) -> Void)?
    private var _onVideoKeyRequest: (@Sendable (Data?, RelaySession) -> Data?)?
    private var _onVideoEnabled: (@Sendable (Data?, Bool) -> Void)?
    private var _onRequestClipboard: (@Sendable () -> ClipboardPayload?)?
    private var _onReceiveClipboard: (@Sendable (ClipboardPayload) -> Void)?

    /// Called when a terminal needs attention and the phone is not connected.
    /// Arguments: APNs device token (hex), notification body.
    var onPushNeeded: (@Sendable (String, String) -> Void)? {
        get { callbackLock.withLock { _onPushNeeded } }
        set { callbackLock.withLock { _onPushNeeded = newValue } }
    }

    var onEvent: (@Sendable (HostEvent) -> Void)? {
        get { callbackLock.withLock { _onEvent } }
        set { callbackLock.withLock { _onEvent = newValue } }
    }

    var onCommand: (@Sendable (RemoteCommand) -> Void)? {
        get { callbackLock.withLock { _onCommand } }
        set { callbackLock.withLock { _onCommand = newValue } }
    }

    var onVideoConnection: (@Sendable (PeerConnection) -> Void)? {
        get { callbackLock.withLock { _onVideoConnection } }
        set { callbackLock.withLock { _onVideoConnection = newValue } }
    }

    /// Called when a client asks for video to move between transports, with the key that
    /// identifies it and the control connection the request arrived on.
    ///
    /// Three arguments rather than one because the decision needs all three: the key says
    /// whether this client is the one being served, the connection is where the picture goes
    /// if it moves, and the request says which way. The server is the only object that has the
    /// control connection and the video pipeline in the same place.
    var onVideoTransport: (@Sendable (Data?, VideoTransportRequest, PeerConnection) -> Void)? {
        get { callbackLock.withLock { _onVideoTransport } }
        set { callbackLock.withLock { _onVideoTransport = newValue } }
    }

    /// Called when a relayed client asks for the secret that seals video datagrams, with the
    /// key that identifies it and the allocation the session came from.
    ///
    /// Answers with the secret when a datagram lane was set up for that client, or `nil` when
    /// it was refused — which is what the session turns into silence rather than an error.
    /// The key and the allocation are both here rather than in the session because only the
    /// server knows which allocation a given connection arrived through.
    var onVideoKeyRequest: (@Sendable (Data?, RelaySession) -> Data?)? {
        get { callbackLock.withLock { _onVideoKeyRequest } }
        set { callbackLock.withLock { _onVideoKeyRequest = newValue } }
    }

    /// Called when a client asks for the picture to be turned on or off, with the key that
    /// identifies it.
    ///
    /// The key rather than the connection, because the two are not the same socket: a direct
    /// session's frames go out on a video connection of their own, and on a relayed one they go
    /// out on the control connection this request arrived on. The key is the only thing that
    /// names the same client on both paths, which is why the video connection's authorization
    /// is built on it too.
    var onVideoEnabled: (@Sendable (Data?, Bool) -> Void)? {
        get { callbackLock.withLock { _onVideoEnabled } }
        set { callbackLock.withLock { _onVideoEnabled = newValue } }
    }

    /// Called when any client requests the host clipboard. Return `nil` to send nothing.
    var onRequestClipboard: (@Sendable () -> ClipboardPayload?)? {
        get { callbackLock.withLock { _onRequestClipboard } }
        set { callbackLock.withLock { _onRequestClipboard = newValue } }
    }

    /// Called when any client pushes its clipboard to the host.
    var onReceiveClipboard: (@Sendable (ClipboardPayload) -> Void)? {
        get { callbackLock.withLock { _onReceiveClipboard } }
        set { callbackLock.withLock { _onReceiveClipboard = newValue } }
    }

    enum Failure: LocalizedError {
        case invalidPort(UInt16)
        case listenerFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "Port \(port) is not a usable TCP port."
            case .listenerFailed(let reason):
                return "The listener could not start: \(reason)"
            }
        }
    }

    init(
        identity: SelfSignedIdentity,
        device: DeviceIdentity,
        pins: PinStore,
        port: UInt16 = ProtocolInfo.defaultPort
    ) {
        self.identity = identity
        self.device = device
        self.pins = pins
        self.port = port
    }

    // The bound port is reported through `.listening(port:)` rather than stored here.
    // Writing it on the queue and reading it from the UI would be a data race for no gain.

    // MARK: - Lifecycle

    func allPushTokens() -> [String] {
        terminalManager.allPushTokens()
    }

    /// Every registered token, connected or not. See ``TerminalSessionManager/registeredPushTokens()``.
    func registeredPushTokens() -> [String] {
        terminalManager.registeredPushTokens()
    }

    func connectedPushClientCount() -> Int {
        terminalManager.connectedPushClientCount()
    }

    func start() throws {
        guard listener == nil else { return }
        terminalManager.onPushNeeded = { [weak self] token, message, _ in
            self?.onPushNeeded?(token, message)
        }

        let tls = try TLSConfig.serverOptions(identity: identity, queue: queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // Without this a restart during development fails to bind for up to a minute.
        parameters.allowLocalEndpointReuse = true

        guard let endpoint = NWEndpoint.Port(rawValue: port) else {
            throw Failure.invalidPort(port)
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: endpoint)
        } catch {
            throw Failure.listenerFailed(error.localizedDescription)
        }

        listener.service = bonjourService

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                emit(.listening(port: listener.port?.rawValue ?? port))
            case .failed(let error):
                emit(.failed(error.localizedDescription))
                stop()
            case .cancelled:
                emit(.stopped)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        self.listener = listener
        listener.start(queue: queue)

        let reaper = DispatchSource.makeTimerSource(queue: queue)
        reaper.schedule(deadline: .now() + Self.reaperInterval, repeating: Self.reaperInterval)
        reaper.setEventHandler { [weak self] in self?.reapSilentSessions() }
        reaper.resume()
        self.reaper = reaper
    }

    func stop() {
        // Strong capture: HostModel sets server = nil immediately after calling stop(), which
        // can deallocate the server before the async block runs. A weak capture would then
        // skip listener?.cancel(), leaving the port held and the next start() unable to bind.
        queue.async { [self] in
            reaper?.cancel()
            reaper = nil
            listener?.cancel()
            listener = nil
            for session in controlSessions { session.cancel() }
            for entry in videoConnections { entry.peer.cancel() }
            for tunnel in pendingRelayBridges + activeRelayBridges { tunnel.bridge.cancel() }
            controlSessions.removeAll()
            videoConnections.removeAll()
            pendingRelayBridges.removeAll()
            activeRelayBridges.removeAll()
        }
    }

    /// Forgets every paired client. The UI calls this after confirming with the user.
    func unpairAll() -> Bool {
        pins.removeAll()
    }

    /// Revokes one client and ends any session it already has open.
    ///
    /// Removing the pin only changes the next handshake. A phone that is already authorized
    /// would otherwise keep its control and video sockets until it chose to disconnect, which
    /// is not what "Forget" promises. The Keychain write is synchronous and lock-protected;
    /// session ownership stays on the server queue.
    func unpair(clientID: String) -> Bool {
        guard pins.remove(peerID: clientID) else { return false }
        queue.async { [weak self] in
            guard let self else { return }
            for session in controlSessions where session.clientID == clientID {
                session.cancel()
            }
        }
        return true
    }

    /// Ends a client's session without revoking it.
    ///
    /// The difference from ``unpair(clientID:)`` is the pin, and it is the whole point: the phone
    /// stays trusted and reconnects by itself. Until this existed, the only way to end a session
    /// from the Mac was to forget the device — which costs a pairing code and a walk to the Mac,
    /// on a host whose whole design is that nobody has to walk to it.
    func disconnect(clientID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            for session in controlSessions where session.clientID == clientID {
                session.cancel()
            }
        }
    }

    var pairedClientIDs: [String] { pins.peerIDs }

    // MARK: - Advertising

    /// What this Mac announces on the network.
    ///
    /// The TXT record carries the persistent device ID, which is what lets a client recognise
    /// this Mac across networks and DHCP leases. The ID is stable; the advertised address is not.
    ///
    /// Built rather than stored so it can be put back after being withdrawn, without a second
    /// copy of the record that could disagree with this one.
    private var bonjourService: NWListener.Service {
        NWListener.Service(
            name: device.name,
            type: ProtocolInfo.bonjourServiceType,
            txtRecord: NWTXTRecord([
                ProtocolInfo.TXTRecordKey.deviceID: device.id,
                ProtocolInfo.TXTRecordKey.deviceName: device.name,
                ProtocolInfo.TXTRecordKey.protocolVersion: String(ProtocolInfo.version),
            ])
        )
    }

    /// Withdraws the Mac from the network while a device is using it, and puts it back when the
    /// last one leaves.
    ///
    /// A Mac serves whichever device connects and nothing in the protocol arbitrates between two
    /// of them, so a second phone that can see this Mac is a second phone that can drive it —
    /// mid-sentence, while the first user watches their own cursor move, and with neither of them
    /// told. Withdrawing the advertisement is the whole of the fix, and it costs almost nothing:
    /// the listener stays up, so a device already connected is unaffected, a *paired* device still
    /// reaches this Mac through the relay, and a phone on the same network finds it again the
    /// moment the session ends.
    ///
    /// Withdrawn on *authorization* rather than on connection, which is the distinction that
    /// keeps a failed handshake from hiding the Mac.
    /// How long a session may go unheard before it is treated as gone.
    ///
    /// The app pings once a second for the whole life of a session, so this is sixty missed
    /// pings — unambiguous, and far shorter than the "still connected" a vanished client used to
    /// be shown as, which was however long the host stayed open.
    ///
    /// **Sixty rather than fifteen, and the difference is the point.** What this actually tests
    /// is "the client sends nothing on control", and sending is a *client* behaviour rather than
    /// something the protocol guarantees — which showed up immediately in testing. The probe
    /// (`Tools/MacCastProbe`) speaks the protocol through a raw `FrameChannel` and never runs the
    /// app's ping loop at all, so a `--video-recv` window went quiet on control by design and a
    /// fifteen-second limit killed a session that was streaming 75 frames a second at the time.
    /// A limit tuned to the app's cadence is a limit that breaks every other client, so this one
    /// is set where only genuine absence reaches it.
    ///
    /// Still deliberately longer than the ~30 seconds iOS can grant an app in the background, so
    /// that switching away and coming straight back does not cost the user their session.
    private static let silenceLimit: TimeInterval = 60

    /// How long a connection may occupy a session slot without completing authentication.
    ///
    /// Authorized sessions get the deliberately generous limit above because a real client can
    /// spend time suspended in the background. A connection that has not authenticated has no
    /// reason to retain a socket indefinitely, and doing so lets a peer accumulate half-open
    /// handshakes for as long as the host runs. Thirty seconds still leaves ample time to compare
    /// and confirm the first-pairing code.
    private static let handshakeSilenceLimit: TimeInterval = 30

    /// How often to look. Well under the limit, so a session is ended within a few seconds of
    /// going quiet rather than up to a whole interval late.
    private static let reaperInterval: TimeInterval = 5

    /// Ends sessions whose client has stopped answering.
    ///
    /// This is what makes the withdrawal in ``updateAdvertisement()`` safe to have. That
    /// withdrawal is the right behaviour — a Mac mid-session should not be offering itself to a
    /// second phone — but it means a session that the host believes in and the client does not
    /// is a Mac that has removed itself from the network. Nothing else here would ever notice:
    /// the connection stays open, `isAuthorized` stays true, and the 18-minute phantom that
    /// prompted this had its last real frame long before it was looked at.
    ///
    /// **Video connections are not its business, and reading the two limits below as though they
    /// covered everything is the bug this guard fixes.** A video connection is silent by design:
    /// on a direct session it carries frames out and only the role frame in, so nothing on it is
    /// ever heard again and `silence` runs away from the moment it opens. It is also never
    /// `isAuthorized`, for the reasons ``HostSession/isVideoConnection`` sets out, so the shorter
    /// handshake limit applied to it and closed the picture thirty seconds into every session.
    /// The half-open handshakes this limit exists for are connections that never presented a role;
    /// these presented one, and the only thing that ends them is the control session they belong
    /// to.
    ///
    /// **Skipping them leaves nothing behind.** The control session they belong to is still reaped
    /// on its own limit, and its end sweeps the video connections for its key, so a phone that
    /// vanishes without a FIN still loses its picture socket, at sixty seconds rather than thirty.
    private func reapSilentSessions() {
        for session in controlSessions where !session.isVideoConnection {
            let limit = session.isAuthorized ? Self.silenceLimit : Self.handshakeSilenceLimit
            guard session.silence > limit else { continue }
            if session.isAuthorized {
                sessionLog.notice("A device stopped answering; ending its session")
            } else {
                sessionLog.notice("An unauthenticated connection stopped answering; ending its handshake")
            }
            // `cancel()` closes the connection and the close handler does everything else —
            // the session leaves the list, its video streams end, and the advertisement goes
            // back up. Doing any of that here as well would do it twice.
            session.cancel()
        }
    }

    private func updateAdvertisement() {
        guard let listener else { return }
        let inUse = controlSessions.contains { $0.isAuthorized }
        if inUse {
            guard listener.service != nil else { return }
            listener.service = nil
            sessionLog.notice("A device is connected; withdrawn from Bonjour")
        } else if listener.service == nil {
            listener.service = bonjourService
            sessionLog.notice("No devices connected; advertising again")
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let tunnel = pendingRelayBridges.isEmpty ? nil : pendingRelayBridges.removeFirst()
        if let tunnel { activeRelayBridges.append(tunnel) }
        let relayBridge = tunnel?.bridge
        let peer = PeerConnection(connection: connection, queue: queue)

        let session = HostSession(
            connection: peer,
            identity: identity,
            device: device,
            pins: pins,
            // A relayed connection reaches this same `accept` through the loopback bridge, so
            // the pending allocation is the only thing that knows where it really came from.
            arrivedThroughRelay: relayBridge != nil,
            emit: { [weak self] event in self?.emit(event) }
        )
        session.onCommand = { [weak self] command in
            self?.onCommand?(command)
        }
        session.onRequestClipboard = { [weak self] in
            self?.onRequestClipboard?()
        }
        session.onReceiveClipboard = { [weak self] payload in
            self?.onReceiveClipboard?(payload)
        }
        session.onVideoTransportRequest = { [weak self, weak session] request in
            guard let self, let session else { return }
            // The control peer, not a lookup: this is the connection the request arrived on,
            // so it is the connection that can carry the answer. The session's key is what
            // ties it to the video connection already being served.
            self.onVideoTransport?(session.peerPublicKey, request, peer)
        }
        // The key and not the connection, unlike the transport request above: what this answer
        // acts on is whichever connection is currently being sent frames, and on a direct
        // session that is a socket this request did not arrive on.
        session.onVideoEnabled = { [weak self, weak session] enabled in
            guard let self, let session else { return }
            self.onVideoEnabled?(session.peerPublicKey, enabled)
        }
        session.onTerminalRequest = { [weak self, weak session] request, sink in
            guard let self, let session else { return }
            self.terminalManager.handle(clientID: session.clientID, request: request, sink: sink)
        }
        // Only a session that arrived through the relay has anywhere to send datagrams, and
        // the allocation that says where came in with it. A direct session's request is
        // answered with the same silence as one from a client that is not being served: it has
        // its own video connection, and a datagram path across the internet is not something
        // this Mac can offer it.
        if let relaySession = tunnel?.session {
            session.onVideoKeyRequest = { [weak self, weak session] in
                guard let self, let session else { return nil }
                return self.onVideoKeyRequest?(session.peerPublicKey, relaySession)
            }
        }
        session.onVideoConnection = { [weak self] videoPeer in
            guard let self else { return }
            guard let key = videoPeer.peerPublicKey,
                  controlSessions.contains(where: { $0.isAuthorized && $0.peerPublicKey == key })
            else {
                // **This is the only thing authorizing a video connection, so it is not a
                // formality.** A video connection carries no handshake of its own — it does
                // not even say which client it belongs to — and the server's TLS verify
                // block deliberately accepts any self-signed chain, because authenticity in
                // this design comes from pairing rather than from a CA. So "completed a TLS
                // handshake" proves nothing at all, and without this check any peer that can
                // reach the port could ask for the user's screen and get it.
                //
                // The client key is the thing that ties the two sockets together: it comes
                // from the peer's certificate, so a client cannot claim one it does not hold.
                videoLog.notice("refused a video connection with no authorized control session")
                emit(.failed("Refused a video connection from an unauthorized client"))
                videoPeer.cancel()
                return
            }

            videoConnections.append((peer: videoPeer, clientKey: key))
            let previousClose = videoPeer.onClose
            videoPeer.onClose = { [weak self, weak videoPeer] error in
                previousClose?(error)
                guard let self, let videoPeer else { return }
                // A video socket is independent from control and may reconnect several times
                // during one session. Remove it as soon as it closes rather than retaining every
                // old PeerConnection until control eventually ends.
                self.videoConnections.removeAll { $0.peer === videoPeer }
            }
            onVideoConnection?(videoPeer)
        }
        // Set for every session, not only the relayed ones, because it is now the moment the
        // advertisement is withdrawn as well as the moment a relayed video connection is handed
        // over — see ``updateAdvertisement()``.
        session.onAuthorized = { [weak self] controlPeer in
            guard let self else { return }
            self.updateAdvertisement()
            // The remote transport multiplexes encoded video onto this same TLS stream. The
            // relay still cannot read it; it is the same authenticated connection as control.
            if relayBridge != nil {
                self.onVideoConnection?(controlPeer)
            }
        }

        session.onEnded = { [weak self] in
            guard let self else { return }
            self.terminalManager.disconnect(clientID: session.clientID)
            // Pruning matters for more than tidiness — a finished session left in the list
            // would go on authorizing video connections, since `isAuthorized` stays true on
            // an object whose connection is gone.
            controlSessions.removeAll { $0 === session }
            // And the streams authorized by it end with it. "Stop sharing" has to actually
            // stop: a video connection that outlived its control session would keep
            // delivering the screen to a client the host believes is gone.
            //
            // **And only when nothing else holds this key**, which is a narrower question than
            // "is this a control session" and the one that matters here. A phone whose network
            // moved dials again while the old socket's close is still on its way, or is still
            // waiting out the sixty seconds a silent connection is given; the replacement can
            // therefore be authorized, and have its video connection attached, before this fires.
            // Sweeping by key then cancels the picture that had just come back, and the client is
            // left dialling into a host that keeps closing the answer.
            //
            // A video connection's own end needs no sweeping at all: the entry it left in
            // `videoConnections` goes with its close handler.
            let keyIsStillServed = controlSessions.contains {
                $0.isAuthorized && $0.peerPublicKey == session.peerPublicKey
            }
            if !session.isVideoConnection, !keyIsStillServed {
                closeVideoConnections(for: session.peerPublicKey)
            }
            // Last one out puts the Mac back on the network.
            self.updateAdvertisement()
            if let relayBridge {
                relayBridge.cancel()
                activeRelayBridges.removeAll { $0.bridge === relayBridge }
            }
        }

        controlSessions.append(session)
        session.start()
    }

    /// Opens the host half of a relay session. A tiny loopback bridge feeds the outbound internet
    /// socket back into this listener, so Network.framework still sees an accepted TLS connection
    /// and preserves the Mac's server role and the existing mTLS/pinning implementation.
    func connectThroughRelay(_ relaySession: RelaySession) {
        queue.async { [weak self] in
            guard let self, self.listener != nil else { return }
            do {
                let tunnelID = UUID()
                let bridge = try RelayControlBridge(
                    session: relaySession,
                    localPort: self.port,
                    onClose: { [weak self] in
                        // RelayByteSplice owns a different queue. Return ownership changes to the
                        // server queue so an accept and a close are ordered with the two arrays.
                        self?.queue.async { [weak self] in
                            self?.relayTunnelClosed(id: tunnelID)
                        }
                    }
                )
                self.pendingRelayBridges.append(RelayTunnel(
                    id: tunnelID,
                    bridge: bridge,
                    session: relaySession
                ))
                bridge.start()
            } catch {
                self.emit(.failed("Could not open the relay control tunnel: \(error.localizedDescription)"))
            }
        }
    }

    /// Drops a relay allocation whether its loopback connection was accepted yet or not.
    ///
    /// In particular, a bridge that fails before `accept` must leave the pending FIFO. Otherwise
    /// the next unrelated connection consumes its allocation and is incorrectly treated as the
    /// relayed client. Active bridges are removed here too; their local EOF independently closes
    /// the corresponding HostSession.
    private func relayTunnelClosed(id: UUID) {
        pendingRelayBridges.removeAll { $0.id == id }
        activeRelayBridges.removeAll { $0.id == id }
    }

    /// Pushes an updated capture catalogue to every authorized client.
    ///
    /// Every client, not the one that caused the change: the catalogue is host-wide state,
    /// and two devices looking at the same Mac disagreeing about what is capturable is a
    /// bug the user would see as one of them offering a source that no longer exists.
    ///
    /// Hops to the server queue because that is where `controlSessions` lives and where
    /// every session mutates its state — see ``HostSession``.
    func broadcastCatalog(_ catalog: CaptureCatalog) {
        queue.async { [weak self] in
            guard let self else { return }
            for session in self.controlSessions {
                session.sendCatalog(catalog)
            }
        }
    }

    /// Says the same thing to every attached client.
    ///
    /// Every client, for the same reason ``broadcastCatalog(_:)`` does: what this describes is
    /// a fact about this Mac — its screen is dark — and not about one session.
    func broadcastNotice(_ payload: NoticePayload) {
        queue.async { [weak self] in
            guard let self else { return }
            for session in self.controlSessions {
                session.sendNotice(payload)
            }
        }
    }

    private func closeVideoConnections(for clientKey: Data?) {
        guard let clientKey else { return }
        let closing = videoConnections.filter { $0.clientKey == clientKey }
        videoConnections.removeAll { $0.clientKey == clientKey }
        for entry in closing { entry.peer.cancel() }
    }

    private func emit(_ event: HostEvent) {
        onEvent?(event)
    }
}
