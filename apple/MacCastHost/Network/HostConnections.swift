import Foundation
import MacCastKit
import RemoteCore

/// Everything the listener tracks about its connections, in one value that is only touched on the server's queue: control sessions, relay tunnels waiting for or carrying a connection, the pairing prompt, and video connections.
struct HostConnections {
    /// A relay session's local end, and the allocation the relay gave it.
    struct RelayTunnel {
        let id: UUID
        let bridge: RelayControlBridge
        let session: RelaySession
    }

    struct VideoConnection {
        let peer: PeerConnection
        let clientKey: Data
    }

    private(set) var sessions: [HostSession] = []
    private var pendingTunnels: [RelayTunnel] = []
    private var activeTunnels: [RelayTunnel] = []
    private var tunnelMatcher = RelayTunnelMatcher()
    private var pairingGate = PairingGate()
    private var videoConnections: [VideoConnection] = []

    // MARK: - Sessions

    mutating func add(_ session: HostSession) {
        sessions.append(session)
    }

    mutating func remove(_ session: HostSession) {
        sessions.removeAll { $0 === session }
    }

    func session(id: UUID) -> HostSession? {
        sessions.first { $0.id == id }
    }

    var hasAuthorizedSession: Bool {
        sessions.contains { $0.isAuthorized }
    }

    func isAuthorized(key: Data?) -> Bool {
        sessions.contains { $0.isAuthorized && $0.peerPublicKey == key }
    }

    func authorizedCount(clientID: String) -> Int {
        sessions.filter { $0.isAuthorized && $0.clientID == clientID }.count
    }

    /// Addresses of connections that have not finished their handshake, for the admission decision.
    var unauthenticatedAddresses: [String] {
        sessions.filter { !$0.isAuthorized && !$0.isVideoConnection }.map(\.address)
    }

    // MARK: - Pairing prompt

    mutating func claimPairingPrompt(session: UUID, address: String, now: ContinuousClock.Instant) -> PairingGate.Refusal? {
        pairingGate.claim(session: session, address: address, now: now)
    }

    mutating func releasePairingPrompt(session: UUID) -> Bool {
        pairingGate.release(session: session)
    }

    func holdsPairingPrompt(_ session: UUID) -> Bool {
        pairingGate.holds(session)
    }

    mutating func evictStalePairingHolder(now: ContinuousClock.Instant) -> UUID? {
        pairingGate.evictStaleHolder(now: now)
    }

    // MARK: - Relay tunnels

    /// False when too many tunnels are already waiting for a connection.
    mutating func reserveTunnel(_ id: UUID, now: ContinuousClock.Instant) -> Bool {
        tunnelMatcher.add(id, now: now)
    }

    mutating func addPending(_ tunnel: RelayTunnel) {
        pendingTunnels.append(tunnel)
    }

    /// The tunnel an inbound loopback connection belongs to, now moved from waiting to carrying.
    mutating func claimTunnel(loopbackPort: UInt16?, now: ContinuousClock.Instant) -> RelayTunnel? {
        let ports = Dictionary(uniqueKeysWithValues: pendingTunnels.compactMap { tunnel in
            tunnel.bridge.localSourcePort.map { (tunnel.id, $0) }
        })
        guard let id = tunnelMatcher.claim(loopbackPort: loopbackPort, knownPorts: ports, now: now),
              let index = pendingTunnels.firstIndex(where: { $0.id == id })
        else { return nil }
        let tunnel = pendingTunnels.remove(at: index)
        activeTunnels.append(tunnel)
        return tunnel
    }

    /// Tunnels no connection claimed in time, removed here for the caller to close.
    mutating func expireUnclaimedTunnels(now: ContinuousClock.Instant) -> [RelayTunnel] {
        let expired = tunnelMatcher.expire(now: now)
        let unclaimed = pendingTunnels.filter { expired.contains($0.id) }
        pendingTunnels.removeAll { expired.contains($0.id) }
        return unclaimed
    }

    /// A relay allocation whether its loopback connection was accepted yet or not.
    mutating func releaseTunnel(id: UUID) {
        pendingTunnels.removeAll { $0.id == id }
        tunnelMatcher.remove(id)
        activeTunnels.removeAll { $0.id == id }
    }

    mutating func releaseActiveTunnel(bridge: RelayControlBridge) {
        activeTunnels.removeAll { $0.bridge === bridge }
    }

    /// For stopping: the tunnels still waiting, removed for the caller to close.
    mutating func takePendingTunnels() -> [RelayTunnel] {
        defer {
            pendingTunnels.removeAll()
            tunnelMatcher = RelayTunnelMatcher()
        }
        return pendingTunnels
    }

    /// For the end of stopping: every session and tunnel still held, removed for the caller to close.
    mutating func takeAllSessionsAndActiveTunnels() -> (sessions: [HostSession], tunnels: [RelayTunnel]) {
        defer {
            sessions.removeAll()
            activeTunnels.removeAll()
        }
        return (sessions, activeTunnels)
    }

    // MARK: - Video

    mutating func add(video peer: PeerConnection, clientKey: Data) {
        videoConnections.append(VideoConnection(peer: peer, clientKey: clientKey))
    }

    mutating func remove(video peer: PeerConnection) {
        videoConnections.removeAll { $0.peer === peer }
    }

    /// Every video connection a client key authorized, removed for the caller to close.
    mutating func takeVideo(clientKey: Data) -> [PeerConnection] {
        let closing = videoConnections.filter { $0.clientKey == clientKey }.map(\.peer)
        videoConnections.removeAll { $0.clientKey == clientKey }
        return closing
    }

    mutating func takeAllVideo() -> [PeerConnection] {
        defer { videoConnections.removeAll() }
        return videoConnections.map(\.peer)
    }
}
