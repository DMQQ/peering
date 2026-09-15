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
    private var controlSessions: [HostSession] = []
    private var pendingRelayBridges: [RelayControlBridge] = []
    private var activeRelayBridges: [RelayControlBridge] = []

    /// Each video connection is tagged with the client key that authorized it, so it can be
    /// torn down when that client's control session ends.
    private var videoConnections: [(peer: PeerConnection, clientKey: Data)] = []

    private let callbackLock = NSLock()
    private var _onEvent: (@Sendable (HostEvent) -> Void)?
    private var _onCommand: (@Sendable (RemoteCommand) -> Void)?
    private var _onVideoConnection: (@Sendable (PeerConnection) -> Void)?

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

    func start() throws {
        guard listener == nil else { return }

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
    }

    func stop() {
        // Strong capture: HostModel sets server = nil immediately after calling stop(), which
        // can deallocate the server before the async block runs. A weak capture would then
        // skip listener?.cancel(), leaving the port held and the next start() unable to bind.
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for session in controlSessions { session.cancel() }
            for entry in videoConnections { entry.peer.cancel() }
            for bridge in pendingRelayBridges + activeRelayBridges { bridge.cancel() }
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
        let relayBridge = pendingRelayBridges.isEmpty ? nil : pendingRelayBridges.removeFirst()
        if let relayBridge { activeRelayBridges.append(relayBridge) }
        let peer = PeerConnection(connection: connection, queue: queue)

        let session = HostSession(
            connection: peer,
            identity: identity,
            device: device,
            pins: pins,
            emit: { [weak self] event in self?.emit(event) }
        )
        session.onCommand = { [weak self] command in
            self?.onCommand?(command)
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
            // Pruning matters for more than tidiness — a finished session left in the list
            // would go on authorizing video connections, since `isAuthorized` stays true on
            // an object whose connection is gone.
            controlSessions.removeAll { $0 === session }
            // And the streams authorized by it end with it. "Stop sharing" has to actually
            // stop: a video connection that outlived its control session would keep
            // delivering the screen to a client the host believes is gone.
            closeVideoConnections(for: session.peerPublicKey)
            // Last one out puts the Mac back on the network.
            self.updateAdvertisement()
            if let relayBridge {
                relayBridge.cancel()
                activeRelayBridges.removeAll { $0 === relayBridge }
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
                let bridge = try RelayControlBridge(
                    session: relaySession,
                    localPort: self.port
                )
                self.pendingRelayBridges.append(bridge)
                bridge.start()
            } catch {
                self.emit(.failed("Could not open the relay control tunnel: \(error.localizedDescription)"))
            }
        }
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
