import Foundation
import MacCastKit
import Network
import RemoteCore
import os

let sessionLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

final class HostServer: @unchecked Sendable {
    let queue = DispatchQueue(label: "pl.dmq.peering.host.server")

    let identity: SelfSignedIdentity
    let device: DeviceIdentity
    let pins: PinStore

    /// The TCP port to listen on.
    let port: UInt16

    private var listener: NWListener?

    /// Ends sessions whose client has stopped answering, so a dead connection cannot outlive it.
    private var reaper: DispatchSourceTimer?

    /// Everything tracked per connection. Touched only on ``queue``.
    var connections = HostConnections()
    let callbacks = HostServerCallbacks()

    let terminalManager = TerminalSessionManager()
    let agentManager = AgentSessionManager()
    let previewProxy = PreviewProxyService()
    let presence = PhonePresenceRegistry()

    /// Keeps the phone's Live Activities moving while iOS has frozen the app.
    lazy var activityPublisher = HostLiveActivityPublisher(
        hostID: device.id,
        presence: { [presence] in presence.presence(of: $0) },
        observedChats: { [agentManager] in agentManager.liveActivityObservations(for: $0) },
        send: { [weak self] push, done in
            guard let send = self?.callbacks.onActivityPush else { return done() }
            send(push, done)
        }
    )

    /// Answers an approval that belongs to a Claude Code hook in a terminal, not to a chat started from the phone.
    var externalApprovalResolver: (@Sendable (String, AgentApprovalDecision) -> Bool)? {
        get { agentManager.externalApprovals }
        set { agentManager.externalApprovals = newValue }
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

    var isListening: Bool { listener != nil }

    func allPushTokens() -> [String] {
        terminalManager.allPushTokens()
    }

    /// The relay's answer to a Live Activity push that was not sent.
    func activityPushRefused(_ reason: RelayActivityRefusal, requestId: String?) {
        activityPublisher.refused(reason, requestId: requestId)
    }

    func directPathChanged(_ open: Bool) {
        activityPublisher.directPathChanged(open)
    }

    /// For quitting: the cards are ended without stopping the listener, which the process exit takes down.
    func endLiveActivities(completion: @escaping @Sendable () -> Void) {
        activityPublisher.hostStopping(completion: completion)
    }

    func registeredPushTokens() -> [String] {
        terminalManager.registeredPushTokens()
    }

    func connectedPushClientCount() -> Int {
        terminalManager.connectedPushClientCount()
    }

    func start() throws {
        guard listener == nil else { return }
        FileDescriptorLimit.raise()
        wireManagers()
        let listener = try makeListener()
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
        startReaper()
    }

    private func wireManagers() {
        terminalManager.onPushNeeded = { [weak self] token, title, message in
            self?.callbacks.onPushNeeded?(token, title, message)
        }
        agentManager.onPushNeeded = { [weak self] token, title, message, action in
            self?.callbacks.onAgentPushNeeded?(token, title, message, action)
        }
        agentManager.onActivityChanged = { [weak self] active in
            self?.callbacks.onAgentActivity?(active)
        }
        agentManager.onChatStateChanged = { [weak self] clientID in
            self?.activityPublisher.changed(clientID: clientID)
        }
        let presence = presence
        agentManager.presence = { presence.presence(of: $0) }
        terminalManager.presence = { presence.presence(of: $0) }
    }

    private func makeListener() throws -> NWListener {
        let tls = try TLSConfig.serverOptions(identity: identity, queue: queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // Without this a restart during development fails to bind for up to a minute.
        parameters.allowLocalEndpointReuse = true

        guard let endpoint = NWEndpoint.Port(rawValue: port) else {
            throw Failure.invalidPort(port)
        }
        do {
            return try NWListener(using: parameters, on: endpoint)
        } catch {
            Analytics.failed(error, in: .network)
            throw Failure.listenerFailed(error.localizedDescription)
        }
    }

    private func startReaper() {
        let reaper = DispatchSource.makeTimerSource(queue: queue)
        reaper.schedule(deadline: .now() + Self.reaperInterval, repeating: Self.reaperInterval)
        reaper.setEventHandler { [weak self] in self?.reapSilentSessions() }
        reaper.resume()
        self.reaper = reaper
    }

    /// `afterLiveActivitiesEnd` runs once the end events for the phones' cards have left, or after a short timeout, on no particular thread; the relay link is closed from it so they are not cut off.
    func stop(afterLiveActivitiesEnd: @escaping @Sendable () -> Void = {}) {
        activityPublisher.hostStopping(completion: afterLiveActivitiesEnd)
        // Strong capture: HostModel sets server = nil right after calling stop(), which can
        // deallocate the server before this block runs, and a weak capture would skip
        // listener?.cancel(), leaving the port held so the next start() cannot bind.
        queue.async { [self] in
            reaper?.cancel()
            reaper = nil
            listener?.cancel()
            listener = nil
            HostSessionFacts.shared.hostStopped()
            for session in connections.sessions { session.endBecauseHostStopped() }
            for peer in connections.takeAllVideo() { peer.cancel() }
            for tunnel in connections.takePendingTunnels() { tunnel.bridge.cancel() }
            // A relayed session's notice travels through its bridge, so the bridge outlives it
            // briefly; cancelling now would drop the frame and the phone would read a network drop.
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                let remaining = connections.takeAllSessionsAndActiveTunnels()
                for session in remaining.sessions { session.cancel() }
                for tunnel in remaining.tunnels { tunnel.bridge.cancel() }
            }
        }
    }

    /// Revokes every client and ends the sessions they have open: a pin removed under a live session would otherwise leave it running.
    func unpairAll() -> Bool {
        guard pins.removeAll() else { return false }
        HostSessionFacts.shared.allForgotten()
        queue.async { [weak self] in
            self?.connections.sessions.forEach { $0.cancel() }
        }
        return true
    }

    /// Revokes one client and ends any session it already has open.
    func unpair(clientID: String) -> Bool {
        guard pins.remove(peerID: clientID) else { return false }
        HostSessionFacts.shared.forgotten(clientID: clientID)
        disconnect(clientID: clientID)
        return true
    }

    func disconnect(clientID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            for session in connections.sessions where session.clientID == clientID {
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

    /// How often to look. Well under the limit, so a session ends within a few seconds of going
    /// quiet rather than up to a whole interval late.
    private static let reaperInterval: TimeInterval = 5

    /// Ends sessions whose client has stopped answering.
    private func reapSilentSessions() {
        reapStalePairingAndTunnels()
        for session in connections.sessions where !session.isVideoConnection {
            // A person has to find the Mac and click, so this wait is longer than a handshake's, and ends as a declined pairing so the card on the Mac goes away.
            if session.isAwaitingApproval {
                if session.silence > SessionSilenceLimits.approval { session.resolveApproval(approved: false) }
                continue
            }
            guard session.silence > session.silenceLimit else { continue }
            if session.isAuthorized {
                session.endedForSilence = true
                sessionLog.notice("A device stopped answering; ending its session")
            } else {
                sessionLog.notice("An unauthenticated connection stopped answering; ending its handshake")
            }
            if session.isAuthorized { HostSessionFacts.shared.silent(clientID: session.clientID, inBackground: session.pictureState.inBackground) }
            session.cancel()
        }
    }

    func updateAdvertisement() {
        guard let listener else { return }
        if connections.hasAuthorizedSession {
            guard listener.service != nil else { return }
            listener.service = nil
            sessionLog.notice("A device is connected; withdrawn from Bonjour")
        } else if listener.service == nil {
            listener.service = bonjourService
            sessionLog.notice("No devices connected; advertising again")
        }
    }
}
