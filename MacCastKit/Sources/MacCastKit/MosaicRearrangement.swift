import Foundation

/// Which capture each tile of a rearranged canvas is drawn from.
///
/// A reorder moves windows between slots and moves no stream, so the tile order and the capture
/// order differ from that moment on, and confusing the two draws one window's picture in another
/// window's rectangle.
///
/// The mapping is computed from the previous arrangement and its mapping rather than from
/// positions: after one rearrangement a tile's index is no longer a capture's index, so a second
/// rearrangement cannot be answered by looking at where anything is now.
public enum MosaicRearrangement {
    /// The capture behind each tile of an arrangement that is replacing another.
    ///
    /// - Parameters:
    ///   - previous: the capture index each tile of the last arrangement was drawn from, in that
    ///     arrangement's order. ``identity(count:)`` for a compositor that has just started.
    ///   - sources: ``CaptureSource/stableID`` of the window in each tile of the last arrangement,
    ///     in the same order as `previous`.
    ///   - slots: ``CaptureSource/stableID`` wanted in each tile of the new arrangement.
    /// - Returns: the capture index for each tile in `slots`, or `nil` when one names a window the
    ///     last arrangement did not have, meaning the caller must build again rather than draw.
    public static func engineOrder(
        previous: [Int],
        sources: [String],
        slots: [String]
    ) -> [Int]? {
        guard previous.count == sources.count else { return nil }

        var order: [Int] = []
        order.reserveCapacity(slots.count)
        for slot in slots {
            // Two steps: through the window, then through the place that window used to be drawn
            // in. A tile's index is not a capture's index.
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
