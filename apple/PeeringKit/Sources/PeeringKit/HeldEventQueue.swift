import Foundation

/// Events kept in order for a client that is not looking, bounded by their encoded size. When it fills, the oldest go: what the client needs most is where things stand now.
public struct HeldEventQueue<Element: Sendable>: Sendable {
    private var items: [(element: Element, cost: Int)] = []
    private var heldBytes = 0
    public let maximumBytes: Int
    public private(set) var droppedCount = 0

    public init(maximumBytes: Int = 2 * 1024 * 1024) {
        self.maximumBytes = maximumBytes
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public mutating func append(_ element: Element, cost: Int) {
        items.append((element, cost))
        heldBytes += cost
        var cut = 0
        while heldBytes > maximumBytes, cut < items.count - 1 {
            heldBytes -= items[cut].cost
            cut += 1
        }
        if cut > 0 {
            items.removeFirst(cut)
            droppedCount += cut
        }
    }

    /// Everything held, oldest first, leaving the queue empty.
    public mutating func drain() -> [Element] {
        defer {
            items = []
            heldBytes = 0
        }
        return items.map(\.element)
    }
}
