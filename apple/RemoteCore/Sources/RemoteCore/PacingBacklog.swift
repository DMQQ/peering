import Foundation

/// Datagrams waiting to leave in small bursts, strictly in the order they were queued.
/// The order is the point: the reassembler drops the frame it is building when a newer frame's chunk arrives, so a later frame overtaking the tail of an earlier one costs the earlier frame.
struct PacingBacklog<Entry> {
    struct Burst {
        let datagrams: [Data]
        let entry: Entry
        /// The last datagrams of their entry, so the entry's completion is due once these are written.
        let finishesEntry: Bool
    }

    private var entries: [(entry: Entry, remaining: ArraySlice<Data>)] = []

    var isEmpty: Bool { entries.isEmpty }

    mutating func append(_ datagrams: [Data], entry: Entry) {
        entries.append((entry, datagrams[...]))
    }

    /// At most `limit` datagrams, all from the oldest entry.
    mutating func nextBurst(limit: Int) -> Burst? {
        guard let first = entries.first else { return nil }
        let take = min(max(1, limit), first.remaining.count)
        let datagrams = Array(first.remaining.prefix(take))
        let rest = first.remaining.dropFirst(take)
        if rest.isEmpty {
            entries.removeFirst()
        } else {
            entries[0].remaining = rest
        }
        return Burst(datagrams: datagrams, entry: first.entry, finishesEntry: rest.isEmpty)
    }

    /// Everything still waiting, for the owner to settle when it stops.
    mutating func removeAll() -> [Entry] {
        defer { entries.removeAll() }
        return entries.map(\.entry)
    }
}
