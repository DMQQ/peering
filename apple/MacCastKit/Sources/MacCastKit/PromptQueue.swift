import Foundation

/// Questions waiting for one answerer, shown one at a time, each owned by the thing that asked.
/// The owner closing takes its questions with it, so nothing is left waiting for an answer nobody can give.
public struct PromptQueue<Item> {
    private struct Entry {
        let owner: UUID
        let item: Item
    }

    private var entries: [Entry] = []

    public init() {}

    /// The one on screen.
    public var current: Item? { entries.first?.item }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func enqueue(_ item: Item, owner: UUID) {
        entries.append(Entry(owner: owner, item: item))
    }

    /// Answers the one on screen; the next, if any, takes its place.
    public mutating func removeCurrent() -> Item? {
        entries.isEmpty ? nil : entries.removeFirst().item
    }

    public mutating func removeAll(owner: UUID) -> [Item] {
        let removed = entries.filter { $0.owner == owner }.map(\.item)
        entries.removeAll { $0.owner == owner }
        return removed
    }

    public mutating func removeAll() -> [Item] {
        defer { entries = [] }
        return entries.map(\.item)
    }
}
