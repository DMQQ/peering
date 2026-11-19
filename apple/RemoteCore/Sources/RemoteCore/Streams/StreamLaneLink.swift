import Foundation

/// Where a host's streams and its datagram lane meet. The session that owns the streams and the lane that carries them are built at different moments by different parts of the host, and both reach this through the relay bridge they share.
public final class StreamLaneLink: @unchecked Sendable {
    private let lock = NSLock()
    private var send: (@Sendable (Data) -> Void)?
    private var isLive: (@Sendable () -> Bool)?
    private var receiver: (@Sendable (Data) -> Void)?

    public init() {}

    /// Set by the session when it starts streams. A lane built after this carries them instead of the control connection's bytes.
    public var isInUse: Bool { lock.withLock { receiver != nil } }

    public func setReceiver(_ receiver: (@Sendable (Data) -> Void)?) {
        lock.withLock { self.receiver = receiver }
    }

    /// Set by the lane: `send` seals one payload as a ``MessageKind/stream`` datagram and puts it on the wire.
    public func attachLane(send: @escaping @Sendable (Data) -> Void, isLive: @escaping @Sendable () -> Bool) {
        lock.withLock {
            self.send = send
            self.isLive = isLive
        }
    }

    public func detachLane() {
        lock.withLock {
            send = nil
            isLive = nil
        }
    }

    public var laneIsLive: Bool { lock.withLock { isLive }?() == true }

    public func sendOnLane(_ payload: Data) { lock.withLock { send }?(payload) }

    public func receivedOnLane(_ payload: Data) { lock.withLock { receiver }?(payload) }
}
