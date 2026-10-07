import Foundation
import Network
import RemoteCore
import os

private let videoLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")
private let sessionLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

final class HostServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pl.dmq.peering.host.server")

    private let identity: SelfSignedIdentity
    private let device: DeviceIdentity
    private let pins: PinStore

    /// The TCP port to listen on.
    private let port: UInt16

    private var listener: NWListener?

    /// Ends sessions whose client has stopped answering, so a dead connection cannot outlive it.
    private var reaper: DispatchSourceTimer?
    private var controlSessions: [HostSession] = []
    private var pendingRelayBridges: [RelayTunnel] = []
    private var activeRelayBridges: [RelayTunnel] = []
    private let terminalManager = TerminalSessionManager()
    private let agentManager = AgentSessionManager()

    /// A relay session's local end, and the allocation the relay gave it.
    private struct RelayTunnel {
        let id: UUID
        let bridge: RelayControlBridge
        let session: RelaySession
    }

    private var videoConnections: [(peer: PeerConnection, clientKey: Data)] = []

    private let callbackLock = NSLock()
    private var _onPushNeeded: (@Sendable (String, String, String) -> Void)?
    private var _onEvent: (@Sendable (HostEvent) -> Void)?
    private var _onCommand: (@Sendable (RemoteCommand) -> Void)?
    private var _onVideoConnection: (@Sendable (PeerConnection) -> Void)?
    private var _onVideoTransport: (@Sendable (Data?, VideoTransportRequest, PeerConnection) -> Void)?
    private var _onVideoKeyRequest: (@Sendable (Data?, RelaySession) -> Data?)?
    private var _onVideoEnabled: (@Sendable (Data?, Bool) -> Void)?
    private var _onRequestClipboard: (@Sendable () -> ClipboardPayload?)?
    private var _onReceiveClipboard: (@Sendable (ClipboardPayload) -> Void)?

    /// Called when a terminal needs attention, or has finished a command worth mentioning.
    var onPushNeeded: (@Sendable (String, String, String) -> Void)? {
        get { callbackLock.withLock { _onPushNeeded } }
        set { callbackLock.withLock { _onPushNeeded = newValue } }
    }

    private var _onAgentActivity: (@Sendable (Bool) -> Void)?

    /// Called when the set of chats that are doing something becomes empty, or stops being empty.
    var onAgentActivity: (@Sendable (Bool) -> Void)? {
        get { callbackLock.withLock { _onAgentActivity } }
        set { callbackLock.withLock { _onAgentActivity = newValue } }
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
    var onVideoTransport: (@Sendable (Data?, VideoTransportRequest, PeerConnection) -> Void)? {
        get { callbackLock.withLock { _onVideoTransport } }
        set { callbackLock.withLock { _onVideoTransport = newValue } }
    }

    /// Called when a relayed client asks for the secret that seals video datagrams, with the
    /// key that identifies it and the allocation the session came from.
    var onVideoKeyRequest: (@Sendable (Data?, RelaySession) -> Data?)? {
        get { callbackLock.withLock { _onVideoKeyRequest } }
        set { callbackLock.withLock { _onVideoKeyRequest = newValue } }
    }

    /// Called when a client asks for the picture to be turned on or off, with the key that
    /// identifies it.
    var onVideoEnabled: (@Sendable (Data?, Bool) -> Void)? {
        get { callbackLock.withLock { _onVideoEnabled } }
        set { callbackLock.withLock { _onVideoEnabled = newValue } }
    }

    var onRequestClipboard: (@Sendable () -> ClipboardPayload?)? {
        get { callbackLock.withLock { _onRequestClipboard } }
        set { callbackLock.withLock { _onRequestClipboard = newValue } }
    }

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

    // The bound port is reported through `.listening(port:)` rather than stored: writing it on
    // the queue and reading it from the UI would be a data race.

    // MARK: - Lifecycle

    func allPushTokens() -> [String] {
        terminalManager.allPushTokens()
    }

    func registeredPushTokens() -> [String] {
        terminalManager.registeredPushTokens()
    }

    func connectedPushClientCount() -> Int {
        terminalManager.connectedPushClientCount()
    }

    func start() throws {
        guard listener == nil else { return }
        terminalManager.onPushNeeded = { [weak self] token, title, message in
            self?.onPushNeeded?(token, title, message)
        }
        agentManager.onPushNeeded = { [weak self] token, title, message in
            self?.onPushNeeded?(token, title, message)
        }
        agentManager.onActivityChanged = { [weak self] active in
            self?.onAgentActivity?(active)
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
            Analytics.failed(error, in: .network)
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
        // Strong capture: HostModel sets server = nil right after calling stop(), which can
        // deallocate the server before this block runs, and a weak capture would skip
        // listener?.cancel(), leaving the port held so the next start() cannot bind.
        queue.async { [self] in
            reaper?.cancel()
            reaper = nil
            listener?.cancel()
            listener = nil
            for session in controlSessions { session.endBecauseHostStopped() }
            for entry in videoConnections { entry.peer.cancel() }
            for tunnel in pendingRelayBridges { tunnel.bridge.cancel() }
            pendingRelayBridges.removeAll()
            videoConnections.removeAll()
            // A relayed session's notice travels through its bridge, so the bridge outlives it
            // briefly; cancelling now would drop the frame and the phone would read a network drop.
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                for session in controlSessions { session.cancel() }
                for tunnel in activeRelayBridges { tunnel.bridge.cancel() }
                controlSessions.removeAll()
                activeRelayBridges.removeAll()
            }
        }
    }

    func unpairAll() -> Bool {
        pins.removeAll()
    }

    /// Revokes one client and ends any session it already has open.
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
    private static let silenceLimit: TimeInterval = 60

    /// How long a connection may occupy a session slot without completing authentication.
    private static let handshakeSilenceLimit: TimeInterval = 30

    /// How often to look. Well under the limit, so a session ends within a few seconds of going
    /// quiet rather than up to a whole interval late.
    private static let reaperInterval: TimeInterval = 5

    /// Ends sessions whose client has stopped answering.
    private func reapSilentSessions() {
        for session in controlSessions where !session.isVideoConnection {
            let limit = session.isAuthorized ? Self.silenceLimit : Self.handshakeSilenceLimit
            guard session.silence > limit else { continue }
            if session.isAuthorized {
                sessionLog.notice("A device stopped answering; ending its session")
            } else {
                sessionLog.notice("An unauthenticated connection stopped answering; ending its handshake")
            }
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
            // the pending allocation is the only thing that knows where it came from.
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
            self.onVideoTransport?(session.peerPublicKey, request, peer)
        }
        session.onVideoEnabled = { [weak self, weak session] enabled in
            guard let self, let session else { return }
            self.onVideoEnabled?(session.peerPublicKey, enabled)
        }
        session.onTerminalRequest = { [weak self, weak session] request, sink in
            guard let self, let session else { return }
            self.terminalManager.handle(clientID: session.clientID, request: request, sink: sink)
        }
        session.onAgentRequest = { [weak self, weak session] request, sink in
            guard let self, let session else { return }
            self.agentManager.handle(clientID: session.clientID, request: request, sink: sink)
        }
        // Only a session that arrived through the relay has anywhere to send datagrams, and the
        // allocation that says where came in with it. A direct session gets the same silence as a
        // client that is not being served: it has its own video connection.
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
                // This is the only thing authorizing a video connection. Such a connection
                // carries no handshake of its own and does not say which client it belongs to,
                // and the TLS verify block accepts any self-signed chain (authenticity comes from
                // pairing, not a CA), so completing a TLS handshake proves nothing. Without this
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
                self.videoConnections.removeAll { $0.peer === videoPeer }
            }
            onVideoConnection?(videoPeer)
        }
        // Set for every session, not only relayed ones: this is both the moment the advertisement
        // is withdrawn and the moment a relayed video connection is handed over.
        session.onAuthorized = { [weak self] controlPeer in
            guard let self else { return }
            self.updateAdvertisement()
            // The remote transport multiplexes encoded video onto this same TLS stream; it is the
            // same authenticated connection as control, and the relay still cannot read it.
            if relayBridge != nil {
                self.onVideoConnection?(controlPeer)
            }
        }

        session.onEnded = { [weak self] in
            guard let self else { return }
            controlSessions.removeAll { $0 === session }
            if !controlSessions.contains(where: { $0.isAuthorized && $0.clientID == session.clientID }) {
                self.terminalManager.disconnect(clientID: session.clientID)
                self.agentManager.disconnect(clientID: session.clientID)
            }
            // And the streams it authorized end with it: a video connection that outlived its
            // control session would keep delivering the screen to a client the host believes is
            // gone.
            let keyIsStillServed = controlSessions.contains {
                $0.isAuthorized && $0.peerPublicKey == session.peerPublicKey
            }
            if !session.isVideoConnection, !keyIsStillServed {
                closeVideoConnections(for: session.peerPublicKey)
            }
            self.updateAdvertisement()
            if let relayBridge {
                relayBridge.cancel()
                activeRelayBridges.removeAll { $0.bridge === relayBridge }
            }
        }

        controlSessions.append(session)
        session.start()
    }

    func connectThroughRelay(_ relaySession: RelaySession) {
        queue.async { [weak self] in
            guard let self, self.listener != nil else { return }
            do {
                let tunnelID = UUID()
                let bridge = try RelayControlBridge(
                    session: relaySession,
                    localPort: self.port,
                    onClose: { [weak self] in
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
                Analytics.failed(error, in: .network)
                self.emit(.failed("Could not open the relay control tunnel: \(error.localizedDescription)"))
            }
        }
    }

    /// Drops a relay allocation whether its loopback connection was accepted yet or not.
    private func relayTunnelClosed(id: UUID) {
        pendingRelayBridges.removeAll { $0.id == id }
        activeRelayBridges.removeAll { $0.id == id }
    }

    func broadcastCatalog(_ catalog: CaptureCatalog) {
        queue.async { [weak self] in
            guard let self else { return }
            for session in self.controlSessions {
                session.sendCatalog(catalog)
            }
        }
    }

    func broadcastNotice(_ payload: NoticePayload) {
        queue.async { [weak self] in
            guard let self else { return }
            for session in self.controlSessions {
                session.sendNotice(payload)
            }
        }
    }

    func broadcastTextFocus(_ focus: TextFocus) {
        queue.async { [weak self] in
            guard let self else { return }
            for session in self.controlSessions {
                session.sendTextFocus(focus)
            }
        }
    }

    func broadcastFieldState(_ state: FieldState) {
        queue.async { [weak self] in
            guard let self else { return }
            for session in self.controlSessions {
                session.sendFieldState(state)
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
        // A phone that reconnects, or races two routes, can still hold a second connection when one
        // closes. That close is not the phone leaving, and passing it on would end the live one's
        // session, watchers and shells. The closing session is still listed while it reports.
        if case .clientDisconnected(let clientID, _) = event,
           controlSessions.filter({ $0.isAuthorized && $0.clientID == clientID }).count > 1 {
            return
        }
        onEvent?(event)
    }
}
