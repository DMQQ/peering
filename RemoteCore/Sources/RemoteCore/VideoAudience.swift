import Foundation

/// Which client the Mac is sending the picture to, and what a client's request does to that.
///
/// It tracks requests, not connections: a phone holding connections to several Macs keeps every one
/// of them, and only the frame destination changes. A model built from connections alone would tear
/// down and rebuild capture every time its owner looked at another tab. See
/// ``RemoteCommand/setVideoEnabled(_:)``.
///
/// One client is served at a time, so a connection that supersedes another takes the picture from
/// it, which is also what makes pausing per-peer.
public struct VideoAudience<Peer: AnyObject> {
    /// Where a connection sits with respect to the picture.
    public enum Seat: Equatable, Sendable {
        /// Not a connection this Mac is serving or holding: an unrelated socket, or one a newer
        /// connection superseded.
        case unrelated
        /// Open, with no frames going down it. A client that asked for a pause.
        case paused
        /// In the audience, waiting for the stream's first description.
        case waiting
        /// The connection the streamer is sending to.
        case attached
    }

    /// Every change to who is asking for frames advances this.
    ///
    /// Capture start and stop are asynchronous while their ordering is visible to the user, so work
    /// carries the value it was scheduled under and is discarded when it no longer matches: a start
    /// queued for a client that has since asked for no frames must not run.
    public private(set) var generation: UInt64 = 0

    /// A connection that has arrived but cannot be served yet, because the stream has not produced
    /// the parameter sets a decoder needs to start. Held as a connection rather than as a flag so
    /// the attach goes to the one actually waiting.
    private var waiting: Peer?
    /// The connection the streamer is serving.
    private var attached: Peer?
    /// Connections that have asked for no frames, in the order they asked.
    ///
    /// Kept because a connection is the expensive thing to rebuild: a direct session's video socket
    /// costs a fresh TLS handshake, and a relayed session's is its control connection.
    private var paused: [Peer] = []

    public init() {}

    /// The connection the streamer should be sending to, if there is one.
    public var served: Peer? { attached ?? waiting }

    /// Whether anybody is asking for frames.
    ///
    /// The question capture is started and stopped by, and deliberately not "is anything
    /// connected": a paused client holds a connection for minutes and wants no picture on it.
    public var isIdle: Bool { attached == nil && waiting == nil }

    /// The connections whose clients have asked for no frames, oldest first.
    public var pausedConnections: [Peer] { paused }

    // MARK: - Transitions

    /// A video connection has arrived, or a client is asking for frames again on one it paused.
    ///
    /// The two are the same transition, which keeps a resumed connection on the path a new one
    /// already takes: the same keyframe request, the same guarantee that nothing decodable is sent
    /// before the description.
    ///
    /// - Parameter described: whether the stream's description is already known. Without one a
    ///   connection has to wait; with one it can be attached immediately.
    public mutating func connected(_ peer: Peer, described: Bool) {
        generation &+= 1
        // A connection that is connecting is by definition not paused, whether it is the same one
        // coming back or a replacement that supersedes it.
        paused.removeAll { $0 === peer }

        if described {
            waiting = nil
            attached = peer
        } else {
            waiting = peer
        }
    }

    /// The stream has produced its first description.
    ///
    /// - Returns: the connection to attach, or `nil` when nothing was waiting for one. No
    ///   generation is advanced: whether there is an audience has not changed, so there is no
    ///   queued capture work to invalidate.
    public mutating func described() -> Peer? {
        guard let pending = waiting else { return nil }
        waiting = nil
        attached = pending
        return pending
    }

    /// A connection went away.
    ///
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

    /// A client has asked for no frames, and its connection is still open.
    ///
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

    /// Forgets every connection, and the choices that belonged to them.
    ///
    /// A source a client chose and a transport it asked for go with it: a replacement that has
    /// asked for nothing must not inherit them.
    public mutating func removeAll() {
        waiting = nil
        attached = nil
        paused.removeAll()
        generation &+= 1
    }
}
