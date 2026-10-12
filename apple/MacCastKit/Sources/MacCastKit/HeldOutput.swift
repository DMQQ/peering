import Foundation

/// Events for one phone while its connection is backed up: they wait here in order, up to a cap. Past the cap they are dropped and the sessions they belonged to are marked for a replay from the transcript, which is what the phone does for itself after a reconnect.
///
/// Pure. The caller holds its own lock around each call and sends outside it.
public struct HeldOutput<Key: Hashable & Sendable, Element: Sendable>: Sendable {
    public static var defaultCapacity: Int { 256 }

    public struct Batch: Sendable {
        /// Held events, oldest first, for sessions that lost nothing.
        public var events: [Element] = []
        /// Sessions that lost events: replay each from after this index.
        public var resync: [Key: UInt64] = [:]

        public var isEmpty: Bool { events.isEmpty && resync.isEmpty }
    }

    private enum Phase {
        case open, paused, draining
    }

    private struct Held {
        var element: Element
        var key: Key
        var index: UInt64
    }

    private let capacity: Int
    private var phase = Phase.open
    private var held: [Held] = []
    private var resync: [Key: UInt64] = [:]

    public init(capacity: Int = HeldOutput.defaultCapacity) {
        self.capacity = capacity
    }

    public var isHolding: Bool { phase != .open }

    public mutating func pause() {
        phase = .paused
    }

    /// True when the event should be sent now. Otherwise it is held, or dropped with its session marked for a replay.
    public mutating func offer(_ element: Element, key: Key, index: UInt64) -> Bool {
        guard phase != .open else { return true }
        if resync[key] != nil { return false }
        guard held.count < capacity else {
            for dropped in held { markLost(dropped.key, after: dropped.index &- 1) }
            markLost(key, after: index &- 1)
            held.removeAll()
            return false
        }
        held.append(Held(element: element, key: key, index: index))
        return false
    }

    /// What has gathered so far. Events keep being held until ``finishedDraining()`` finds nothing new, so what the caller sends next cannot be overtaken by a live event.
    public mutating func resume() -> Batch {
        guard phase != .open else { return Batch() }
        phase = .draining
        return takeBatch()
    }

    /// More to send if events arrived while the last batch was going out; nil once the queue is open again, or if it was paused again meanwhile.
    public mutating func finishedDraining() -> Batch? {
        guard phase == .draining else { return nil }
        let batch = takeBatch()
        if batch.isEmpty {
            phase = .open
            return nil
        }
        return batch
    }

    private mutating func markLost(_ key: Key, after index: UInt64) {
        resync[key] = min(resync[key] ?? index, index)
    }

    private mutating func takeBatch() -> Batch {
        defer {
            held.removeAll()
            resync.removeAll()
        }
        return Batch(events: held.map(\.element), resync: resync)
    }
}
