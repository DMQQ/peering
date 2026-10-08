import Foundation

/// Tracks requests, not connections: a phone keeps every Mac connection and only the frame destination changes. Built from connections alone it would rebuild capture on every tab switch.
public struct VideoAudience<Peer: AnyObject> {
    public enum Seat: Equatable, Sendable {
        case unrelated
        case paused
        case waiting
        case attached
    }

    /// Capture start and stop are asynchronous while their ordering is visible to the user, so work
    /// carries the value it was scheduled under and is discarded when it no longer matches: a start
    /// queued for a client that has since asked for no frames must not run.
    public private(set) var generation: UInt64 = 0

    private var waiting: Peer?
    private var attached: Peer?
    /// Kept because a connection is the expensive thing to rebuild: a direct session's video socket
    /// costs a fresh TLS handshake, and a relayed session's is its control connection.
    private var paused: [Peer] = []

    public init() {}

    public var served: Peer? { attached ?? waiting }

    /// The question capture is started and stopped by, and deliberately not "is anything
    /// connected": a paused client holds a connection for minutes and wants no picture on it.
    public var isIdle: Bool { attached == nil && waiting == nil }

    public var pausedConnections: [Peer] { paused }

    // MARK: - Transitions

    public mutating func connected(_ peer: Peer, described: Bool) {
        generation &+= 1
        paused.removeAll { $0 === peer }

        if described {
            waiting = nil
            attached = peer
        } else {
            waiting = peer
        }
    }

    public mutating func described() -> Peer? {
        guard let pending = waiting else { return nil }
        waiting = nil
        attached = pending
        return pending
    }

    /// - Returns: where it was. ``Seat/unrelated`` covers both a socket that was never part of the
    ///   audience and one a newer connection had already superseded, and a paused connection that
    ///   closes reports its own case; none of the three changes what the capture is doing.
    @discardableResult
    public mutating func closed(_ peer: Peer) -> Seat {
        let wasPaused = paused.contains { $0 === peer }
        paused.removeAll { $0 === peer }

        let wasWaiting = waiting === peer
        let wasAttached = attached === peer
        guard wasWaiting || wasAttached else { return wasPaused ? .paused : .unrelated }

        if wasWaiting { waiting = nil }
        if wasAttached { attached = nil }
        generation &+= 1
        return wasAttached ? .attached : .waiting
    }

    /// - Returns: where the connection was. ``Seat/unrelated`` means this Mac was not serving it,
    ///   which is what keeps a pause per-peer: a client that never had the picture because a second
    ///   one took it has nothing to stop.
    @discardableResult
    public mutating func pause(_ peer: Peer) -> Seat {
        let wasWaiting = waiting === peer
        let wasAttached = attached === peer
        guard wasWaiting || wasAttached else { return .unrelated }

        if wasWaiting { waiting = nil }
        if wasAttached { attached = nil }
        generation &+= 1
        if !paused.contains(where: { $0 === peer }) { paused.append(peer) }
        return wasAttached ? .attached : .waiting
    }

    /// A source a client chose and a transport it asked for go with it: a replacement that has
    /// asked for nothing must not inherit them.
    public mutating func removeAll() {
        waiting = nil
        attached = nil
        paused.removeAll()
        generation &+= 1
    }
}
