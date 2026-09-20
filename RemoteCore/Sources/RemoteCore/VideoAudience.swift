import Foundation

/// Which client the Mac is sending the picture to, and what a client's request does to that.
///
/// **It tracks *requests*, not connections, and that distinction is the reason it exists.** A
/// phone holding connections to several Macs keeps every one of them: control channels, shells,
/// clipboards and the assertions that keep the Macs awake all stay up, and the only thing that
/// changes is which Mac is being sent frames. A model built from connections alone cannot say
/// that, and the failure it produces is a Mac whose capture is torn down and rebuilt every time
/// its owner looks at another tab, taking the chosen source, the transport the client asked
/// for and the keyframe that follows both with it. See ``RemoteCommand/setVideoEnabled(_:)``.
///
/// **One client is served at a time, and that is deliberate** rather than a limitation of this
/// type: the picture is one stream through one decoder, and a second audience would be a second
/// copy of everything the design exists to keep singular. A connection that supersedes another
/// therefore takes the picture from it, and the superseded one is forgotten. That is also what
/// makes pausing per-peer: a request from a client this Mac is not serving changes nothing, so
/// a second phone's picture does not blink when the first one pauses.
///
/// Nothing here touches a socket, a stream or a clock: the caller supplies its own connection
/// type as `Peer` and acts on what this returns. That is what lets the pause be decided and
/// tested without a Mac, a phone or a frame in flight.
public struct VideoAudience<Peer: AnyObject> {
    /// Where a connection sits with respect to the picture.
    public enum Seat: Equatable, Sendable {
        /// Not a connection this Mac is serving or holding: either an unrelated socket, or one
        /// a newer connection superseded and which has since been forgotten.
        case unrelated
        /// Open, with no frames going down it. A client that asked for a pause.
        case paused
        /// In the audience, waiting for the stream's first description. Nothing can be decoded
        /// before it arrives, so this connection cannot be attached yet.
        case waiting
        /// The connection the streamer is sending to.
        case attached
    }

    /// Every change to who is asking for frames advances this.
    ///
    /// Capture start and stop are asynchronous while their ordering is visible to the user, so
    /// work carries the value it was scheduled under and is discarded when it no longer
    /// matches. A pause is a change like any other: a capture start queued for a client that has
    /// since asked for no frames must not run, and a stop queued before a resume must not run
    /// after it. See the coordinator's `hasAudience(generation:)`.
    public private(set) var generation: UInt64 = 0

    /// A connection that has arrived but cannot be served yet, because the stream has not
    /// produced the parameter sets a decoder needs to start.
    ///
    /// Held as a connection rather than as a flag so the attach goes to the one that is actually
    /// waiting, not to whichever one arrived most recently.
    private var waiting: Peer?
    /// The connection the streamer is serving.
    private var attached: Peer?
    /// Connections that have asked for no frames, in the order they asked.
    ///
    /// Kept because the connection is the expensive thing to rebuild: a direct session's video
    /// socket costs a fresh TLS handshake, and a relayed session's *is* its control connection.
    /// A resume that found nothing here would have to wait for a new connection, which is
    /// exactly the cost the pause exists to avoid. One of these is dropped when its client asks
    /// for frames again, and when its connection closes.
    private var paused: [Peer] = []

    public init() {}

    /// The connection the streamer should be sending to, if there is one.
    public var served: Peer? { attached ?? waiting }

    /// Whether anybody is asking for frames.
    ///
    /// The question the capture is started and stopped by, and it is deliberately not "is
    /// anything connected": a paused client holds a connection for minutes and wants no picture
    /// on it.
    public var isIdle: Bool { attached == nil && waiting == nil }

    /// The connections whose clients have asked for no frames, oldest first.
    public var pausedConnections: [Peer] { paused }

    // MARK: - Transitions

    /// A video connection has arrived, or a client is asking for frames again on one it paused.
    ///
    /// The two are the same transition, and treating them as one is what keeps a resumed
    /// connection on the path a new one already takes: the same keyframe request, the same
    /// guarantee that nothing decodable is sent before the description.
    ///
    /// - Parameter described: whether the stream's description is already known. Without one a
    ///   connection has to wait; with one it can be attached immediately, and the attach is what
    ///   asks the encoder for the keyframe that gives it a picture.
    public mutating func connected(_ peer: Peer, described: Bool) {
        generation &+= 1
        // A connection that is connecting is by definition not paused, whether this is the same
        // connection coming back or a replacement that supersedes it.
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
    ///   queued capture work for this to invalidate.
    public mutating func described() -> Peer? {
        guard let pending = waiting else { return nil }
        waiting = nil
        attached = pending
        return pending
    }

    /// A connection went away.
    ///
    /// - Returns: where it was. ``Seat/unrelated`` covers both a socket that was never part of
    ///   the audience and one a newer connection had already superseded, and a paused
    ///   connection that closes reports its own case; none of the three changes what the
    ///   capture is doing. The generation is deliberately left alone for all of them: work
    ///   queued for the connection actually being served must not be invalidated by a socket
    ///   that has nothing to do with it.
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
    /// - Returns: where the connection was. ``Seat/unrelated`` means this Mac was not serving
    ///   it, which is the case that keeps a pause per-peer: a client that never had the picture
    ///   because a second one took it has nothing to stop, and answering as though it had would
    ///   leave it believing it paused a picture it was never being sent.
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
    /// A source a client chose and a transport it asked for go with it: they belonged to the
    /// audience that has ended, and a replacement that has asked for nothing must not inherit a
    /// decision somebody else made.
    public mutating func removeAll() {
        waiting = nil
        attached = nil
        paused.removeAll()
        generation &+= 1
    }
}
