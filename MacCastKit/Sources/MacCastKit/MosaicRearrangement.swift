import Foundation

/// Which capture each tile of a rearranged canvas is drawn from.
public enum MosaicRearrangement {
    /// The capture behind each tile of an arrangement that is replacing another.
    public static func engineOrder(
        previous: [Int],
        sources: [String],
        slots: [String]
    ) -> [Int]? {
        guard previous.count == sources.count else { return nil }

        var order: [Int] = []
        order.reserveCapacity(slots.count)
        for slot in slots {
            guard let was = sources.firstIndex(of: slot),
                  previous.indices.contains(was)
            else { return nil }
            order.append(previous[was])
        }
        return order
    }

    /// The order a compositor starts with: tile `i` is capture `i`, the one moment the two orders
    /// are the same thing.
    public static func identity(count: Int) -> [Int] {
        Array(0..<max(count, 0))
    }
}
