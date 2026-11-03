import Foundation

/// When each chat last changed and whether it has been looked at since. The Mac sends no such time, so it is the moment this phone first saw the chat's state or last line differ.
public struct ChatChangeClock: Equatable, Sendable {
    private struct Mark: Equatable, Sendable {
        var fingerprint: String
        /// Nil while the chat is as it was when first seen: its real last change happened before this run.
        var changedAt: Date?
    }

    private var marks: [UUID: Mark] = [:]
    private var seenAt: [UUID: Date] = [:]

    public init() {}

    public mutating func observe(_ id: UUID, fingerprint: String, at now: Date) {
        guard let mark = marks[id] else {
            marks[id] = Mark(fingerprint: fingerprint, changedAt: nil)
            return
        }
        guard mark.fingerprint != fingerprint else { return }
        marks[id] = Mark(fingerprint: fingerprint, changedAt: now)
    }

    /// Forgets every chat not in `ids`, so a closed chat's marks do not pile up for the rest of the run.
    public mutating func keepOnly(_ ids: Set<UUID>) {
        marks = marks.filter { ids.contains($0.key) }
        seenAt = seenAt.filter { ids.contains($0.key) }
    }

    public mutating func markSeen(_ id: UUID, at now: Date) {
        seenAt[id] = now
    }

    public func changedAt(_ id: UUID, fallback: Date) -> Date {
        marks[id]?.changedAt ?? fallback
    }

    /// Only a change this run watched can be unread: one from before is not known to be news.
    public func isUnread(_ id: UUID) -> Bool {
        guard let changed = marks[id]?.changedAt else { return false }
        guard let seen = seenAt[id] else { return true }
        return changed > seen
    }
}
