import Foundation

/// Pairs a connection arriving on the host's listener with the relay tunnel that opened it.
/// A tunnel dials the listener over loopback, so a connection from anywhere else is never one, and a loopback connection is matched by the source port the tunnel's own socket reports.
public struct RelayTunnelMatcher: Sendable {
    public static let pendingLifetime: TimeInterval = 10
    public static let maximumPending = 4

    private struct Entry {
        let id: UUID
        let createdAt: ContinuousClock.Instant
    }

    private var pending: [Entry] = []

    public init() {}

    public var pendingIDs: [UUID] { pending.map(\.id) }

    /// - Returns: whether the tunnel was taken; at the cap it is refused rather than a pending one evicted.
    public mutating func add(_ id: UUID, now: ContinuousClock.Instant) -> Bool {
        guard pending.count < Self.maximumPending else { return false }
        pending.append(Entry(id: id, createdAt: now))
        return true
    }

    public mutating func remove(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    /// The tunnels that never produced a connection in time, removed here for the caller to close.
    public mutating func expire(now: ContinuousClock.Instant) -> [UUID] {
        let expired = pending.filter { now - $0.createdAt > .seconds(Self.pendingLifetime) }
        pending.removeAll { entry in expired.contains { $0.id == entry.id } }
        return expired.map(\.id)
    }

    /// - Parameters:
    ///   - loopbackPort: the arriving connection's source port when it came from loopback, nil when it came from anywhere else.
    ///   - knownPorts: the source port each tunnel's socket has reported so far; a tunnel can be accepted before it has learned its own.
    public mutating func claim(loopbackPort: UInt16?, knownPorts: [UUID: UInt16], now: ContinuousClock.Instant) -> UUID? {
        guard let loopbackPort else { return nil }
        let live = pending.filter { now - $0.createdAt <= .seconds(Self.pendingLifetime) }
        let match = live.first { knownPorts[$0.id] == loopbackPort }
            ?? live.first { knownPorts[$0.id] == nil }
        guard let match else { return nil }
        pending.removeAll { $0.id == match.id }
        return match.id
    }
}
