import Foundation

/// Which capture each tile of a rearranged canvas is drawn from.
///
/// **The question a mosaic asks every time the arrangement changes, and the one it used to answer
/// by accident.** A compositor has two orders that are not the same order: the tiles, which are the
/// client's, and the captures behind them, which are the order the streams were built in and which
/// never changes afterwards. A reorder moves windows between slots and moves no stream at all, so
/// from that moment the two orders differ — and anything that confuses them draws one window's
/// picture in another window's rectangle.
///
/// That is what happened. The retained frames were permuted into the new arrangement while the
/// callbacks that fill them went on being indexed by capture, so each tile was overwritten by
/// another tile's picture as the next frame from each stream arrived: the canvas came back in the
/// arrangement it had just been moved out of, and looked like a shuffle on the way through.
///
/// The answer is a mapping rather than a permuted copy of everything else, because the mapping is
/// the only thing that changes. It is computed **from the previous arrangement and its mapping,
/// rather than from positions**, and that is the second half of the same lesson: after one
/// rearrangement a tile's index is no longer a capture's index, so the *second* rearrangement of a
/// session — a window moved and then the phone turned, or two windows moved in turn — cannot be
/// answered by looking at where anything is now.
public enum MosaicRearrangement {
    /// The capture behind each tile of an arrangement that is replacing another.
    ///
    /// - Parameters:
    ///   - previous: the capture index each tile of the *last* arrangement was drawn from, in that
    ///     arrangement's order. ``identity(count:)`` for a compositor that has just started, which
    ///     is the only moment the two orders are the same thing.
    ///   - sources: ``CaptureSource/stableID`` of the window in each tile of the last arrangement,
    ///     in the same order as `previous`.
    ///   - slots: ``CaptureSource/stableID`` wanted in each tile of the new arrangement.
    /// - Returns: the capture index for each tile in `slots`, or `nil` when one of them names a
    ///     window the last arrangement did not have — which is a rearrangement of different
    ///     windows, and one the caller has to build again rather than draw.
    public static func engineOrder(
        previous: [Int],
        sources: [String],
        slots: [String]
    ) -> [Int]? {
        guard previous.count == sources.count else { return nil }

        var order: [Int] = []
        order.reserveCapacity(slots.count)
        for slot in slots {
            // **Through the window, and then through the place that window used to be drawn in.**
            // Two steps, and both are needed: the first says which capture, and the second says
            // that a tile's index is not a capture's index.
            guard let was = sources.firstIndex(of: slot),
                  previous.indices.contains(was)
            else { return nil }
            order.append(previous[was])
        }
        return order
    }

    /// The order a compositor starts with: tile `i` is capture `i`.
    ///
    /// The one moment the two orders are the same thing, written down so that the arithmetic above
    /// has a beginning rather than an assumption.
    public static func identity(count: Int) -> [Int] {
        Array(0..<max(count, 0))
    }
}
