import Foundation

/// Runs ``QuicDirectPathPolicy`` against one relayed ``QuicFrameLink``: asks the relay where the peer is, carries out the policy's actions on the link's socket, and tells the owner what changed.
///
/// `@unchecked Sendable`: `policy` is guarded by `lock`; everything else is immutable.
public final class QuicDirectPath: @unchecked Sendable {
    public enum Change: Sendable, Equatable {
        case report(ClientSession.DirectPath)
        case verdictDue
        case onPath(ClientSession.DatagramPath)
    }

    private let link: QuicFrameLink
    private let videoToken: Data
    private let restarts: @Sendable () -> Int
    private let onChange: @Sendable (Change) -> Void
    private let lock = NSLock()
    private var policy: QuicDirectPathPolicy

    /// `restarts` is a counter the owner bumps when the network changes.
    public init(
        link: QuicFrameLink,
        relay: QuicAddress,
        role: QuicDirectPathPolicy.Role,
        videoToken: Data,
        restarts: @escaping @Sendable () -> Int = { 0 },
        onChange: @escaping @Sendable (Change) -> Void
    ) {
        self.link = link
        self.videoToken = videoToken
        self.restarts = restarts
        self.onChange = onChange
        policy = QuicDirectPathPolicy(role: role, relay: relay)
    }

    public var isDirect: Bool { lock.withLock { policy.direct != nil } }

    /// The Mac's announcement of where it can be reached besides the relay.
    public func announced(_ candidates: DirectCandidates) {
        let addresses = candidates.addresses.compactMap(DirectCandidates.parse).compactMap { QuicAddress(host: $0.host, port: $0.port) }
        lock.withLock { policy.announcedAddresses(addresses) }
    }

    /// Until the task is cancelled.
    public func run() async {
        link.onPathEvent = { [weak self] event in
            guard let self else { return }
            let actions = lock.withLock { policy.handle(event) }
            link.onPath { [weak self] context in _ = self?.perform(actions, context) }
        }
        defer { link.onPathEvent = nil }
        let lookup = RelayPeerLookup(url: ProtocolInfo.relaySignallingURL)
        var seenRestarts = restarts()
        while !Task.isCancelled {
            let asksRelay = await tick()
            if asksRelay { await askRelay(lookup) }
            let interval = lock.withLock { policy.interval }
            var waited = Duration.zero
            while waited < interval, !Task.isCancelled, restarts() == seenRestarts {
                try? await Task.sleep(for: DirectPathSchedule.fastInterval)
                waited += DirectPathSchedule.fastInterval
            }
            if restarts() != seenRestarts {
                seenRestarts = restarts()
                let actions = lock.withLock { policy.networkChanged(now: .now) }
                link.onPath { [weak self] context in _ = self?.perform(actions, context) }
            }
        }
        await lookup.close()
    }

    private func tick() async -> Bool {
        await withCheckedContinuation { continuation in
            link.onPath { [weak self] context in
                guard let self, let context else { return continuation.resume(returning: false) }
                let actions = lock.withLock { policy.tick(now: .now, silence: context.silence) }
                continuation.resume(returning: perform(actions, context))
            }
        }
    }

    private func askRelay(_ lookup: RelayPeerLookup) async {
        guard let answer = try? await lookup.address(videoToken: videoToken) else {
            apply(lock.withLock { policy.peerAddressAnswered(nil) })
            return
        }
        guard let address = QuicAddress(host: answer.host, port: answer.port) else {
            onChange(.report(.addressUnusable(peer: "\(answer.host):\(answer.port)")))
            return
        }
        apply(lock.withLock { policy.peerAddressAnswered(address) })
    }

    /// For actions that need no socket.
    private func apply(_ actions: [QuicDirectPathPolicy.Action]) {
        link.onPath { [weak self] context in _ = self?.perform(actions, context) }
    }

    /// Returns whether the relay should be asked where the peer is.
    private func perform(_ actions: [QuicDirectPathPolicy.Action], _ context: QuicFrameLink.PathContext?) -> Bool {
        var asksRelay = false
        for action in actions {
            switch action {
            case .askRelay: asksRelay = true
            case .probe(let peer): if let context { context.connection.probePath(local: context.local, peer: peer) }
            case .knock(let peer): context?.knock(peer)
            case .migrate(let peer): if let context { context.connection.migrate(local: context.local, peer: peer) }
            case .refreshRelayBinding: context?.refreshRelayBinding()
            case .report(let outcome): onChange(.report(outcome))
            case .verdictDue: onChange(.verdictDue)
            case .onPath(let path): onChange(.onPath(path))
            }
        }
        return asksRelay
    }
}
