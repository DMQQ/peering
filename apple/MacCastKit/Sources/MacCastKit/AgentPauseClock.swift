import Foundation

/// When each chat was paused, as far as this run saw it happen.
public struct AgentPauseClock: Equatable {
    private var pausedAt: [UUID: Date] = [:]
    private var seen: Set<UUID> = []

    public init() {}

    /// Stamps a chat that was seen running and is now paused. A chat first seen already paused was stopped before this run, so it gets no stamp and keeps sorting by when it began.
    public mutating func observe(_ id: UUID, isPaused: Bool, at now: Date) {
        if isPaused {
            if seen.contains(id), pausedAt[id] == nil { pausedAt[id] = now }
        } else {
            pausedAt[id] = nil
        }
        seen.insert(id)
    }

    public func date(for id: UUID, fallback: Date) -> Date {
        pausedAt[id] ?? fallback
    }
}
