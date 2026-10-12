import Foundation

/// Spaces the pushes for one activity token by the relay's minimum gap, so a command that follows another within a second (an `end` right after an update) leaves later instead of being refused, and the order they were planned in is the order they leave.
public struct ActivitySendPacer: Sendable, Equatable {
    private var nextSlot: [String: Date] = [:]

    public init() {}

    /// Seconds to wait before sending to `token`; the slot after it is reserved.
    public mutating func delay(for token: String, now: Date, gap: TimeInterval = LiveActivityPushPlanner.minimumGap) -> TimeInterval {
        nextSlot = nextSlot.filter { $0.value > now }
        let slot = max(now, nextSlot[token] ?? now)
        nextSlot[token] = slot.addingTimeInterval(gap)
        return slot.timeIntervalSince(now)
    }

    /// For a flush that sends at once: whatever was reserved is dropped.
    public mutating func clear() {
        nextSlot.removeAll()
    }
}
