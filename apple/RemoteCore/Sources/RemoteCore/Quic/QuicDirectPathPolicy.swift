import Foundation

/// Decides what a relayed QUIC session does about a path straight to its peer: when to ask the relay where the peer is, what to knock on or probe, when to move onto a validated path, and when to fall back to the relay. Pure, so the timing is tested without sockets.
///
/// The phone (``Role/dialer``) probes and moves; QUIC lets only the client migrate. The Mac (``Role/listener``) knocks so its NAT lets the phone's probes in, and follows wherever the phone's packets come from.
public struct QuicDirectPathPolicy: Sendable {
    public enum Role: Sendable { case dialer, listener }

    public enum Action: Sendable, Equatable {
        case askRelay
        case probe(QuicAddress)
        case knock(QuicAddress)
        case migrate(to: QuicAddress)
        case refreshRelayBinding
        case report(ClientSession.DirectPath)
        /// The attempt has run its time without opening.
        case verdictDue
        case onPath(ClientSession.DatagramPath)
    }

    /// A direct path this long without a single packet is gone (a NAT mapping expired, a network went): back to the relay, whose route is kept warm for this.
    static let silenceBeforeFallback: Duration = .seconds(2)
    /// The relay forgets a route it has not heard from; the bind is repeated while the session runs direct.
    static let relayRefreshInterval: Duration = .seconds(10)
    /// How often the silence on a direct path is checked.
    static let directCheckInterval: Duration = .milliseconds(250)

    public let role: Role
    public let relay: QuicAddress
    private var schedule: DirectPathSchedule
    /// Where the relay saw the peer.
    private var candidate: QuicAddress?
    /// What the Mac said it can be reached at on its own network: the path when both ends share one, since the relay's address for a Mac behind the same router only works if the router loops it back, and most refuse.
    private var announced: [QuicAddress] = []
    public private(set) var direct: QuicAddress?
    private var lastRefresh: ContinuousClock.Instant
    private var verdictGiven = false

    public init(role: Role, relay: QuicAddress, now: ContinuousClock.Instant = .now) {
        self.role = role
        self.relay = relay
        schedule = DirectPathSchedule(now: now)
        lastRefresh = now
    }

    /// Time until the next ``tick(now:silence:)``.
    public var interval: Duration { worthProbing.isEmpty ? Self.directCheckInterval : schedule.intervalToNextProbe }

    /// Addresses that would beat the path in use: any, while on the relay; only one on the Mac's own network, while on a public one.
    private var worthProbing: [QuicAddress] {
        let all = announced + (candidate.map { [$0] } ?? [])
        guard let direct else { return all }
        return Self.isLocal(direct) ? [] : announced.filter { $0 != direct }
    }

    public mutating func tick(now: ContinuousClock.Instant, silence: Duration?) -> [Action] {
        var actions: [Action] = []
        if direct != nil, role == .dialer, let silence, silence > Self.silenceBeforeFallback {
            actions += fallBack()
        }
        if now - lastRefresh >= Self.relayRefreshInterval {
            lastRefresh = now
            actions.append(.refreshRelayBinding)
        }
        let targets = worthProbing
        guard !targets.isEmpty || direct == nil else { return actions }
        if direct == nil, schedule.asksRelayForPeerAddress { actions.append(.askRelay) }
        // The Mac's NAT is opened toward the phone's public address only: a local one needs no knock.
        if let candidate, direct == nil { actions.append(.knock(candidate)) }
        if role == .dialer { actions += targets.map { .probe($0) } }
        schedule.probeSent()
        if direct == nil, !verdictGiven, schedule.verdictIsDue(now: now) {
            verdictGiven = true
            actions.append(.verdictDue)
        }
        return actions
    }

    /// The relay's answer to where the peer is: nil when it has not heard from it yet.
    public mutating func peerAddressAnswered(_ address: QuicAddress?) -> [Action] {
        guard direct == nil else { return [] }
        candidate = address
        return [.report(address.map { .probing(peer: Self.text($0)) } ?? .noAddress)]
    }

    /// The Mac's addresses on its own network, from its announcement.
    public mutating func announcedAddresses(_ addresses: [QuicAddress]) {
        announced = addresses.filter(Self.isLocal)
    }

    public mutating func handle(_ event: QuicConnection.PathEvent) -> [Action] {
        switch (role, event) {
        case (.dialer, .validated(_, let peer)) where peer != relay && Self.beats(peer, direct):
            direct = peer
            return [.migrate(to: peer), .report(.open(peer: Self.text(peer))), .onPath(Self.kind(of: peer))]
        case (.listener, .peerMigrated(_, let peer)):
            if peer == relay { return fallBack() }
            guard direct != peer else { return [] }
            direct = peer
            return [.report(.open(peer: Self.text(peer))), .onPath(Self.kind(of: peer))]
        case (_, .failedValidation(_, let peer)), (_, .closed(_, let peer)):
            return peer == direct ? fallBack() : []
        default:
            return []
        }
    }

    /// The phone's network changed: whatever path was proven belongs to the old one.
    public mutating func networkChanged(now: ContinuousClock.Instant) -> [Action] {
        schedule.restart(now: now)
        candidate = nil
        verdictGiven = false
        return fallBack() + [.report(.notTried)]
    }

    private mutating func fallBack() -> [Action] {
        guard direct != nil else { return [] }
        direct = nil
        return role == .dialer ? [.migrate(to: relay), .onPath(.relay)] : [.onPath(.relay)]
    }

    /// Whether `peer` is a better path than `current`: anything beats the relay, and the Mac's own network beats a public address.
    static func beats(_ peer: QuicAddress, _ current: QuicAddress?) -> Bool {
        guard let current else { return true }
        return isLocal(peer) && !isLocal(current)
    }

    static func kind(of address: QuicAddress) -> ClientSession.DatagramPath {
        isLocal(address) ? .lan : .direct
    }

    /// A private IPv4 address: reachable only inside the network it belongs to.
    static func isLocal(_ address: QuicAddress) -> Bool {
        let host = address.hostText
        let bare = host.hasPrefix("::ffff:") ? String(host.dropFirst(7)) : host
        return bare.contains(".") && !DirectCandidates.isPubliclyRoutable(ipv4: bare)
    }

    static func text(_ address: QuicAddress) -> String {
        let host = address.hostText
        let bare = host.hasPrefix("::ffff:") ? String(host.dropFirst(7)) : host
        return "\(bare):\(address.port)"
    }
}
