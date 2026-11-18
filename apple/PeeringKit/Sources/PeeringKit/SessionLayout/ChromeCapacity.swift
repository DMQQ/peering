import CoreGraphics

/// How much a strip of controls holds, so a wide dock or a tall rail fills with buttons and a cramped one keeps fewer.
public enum ChromeCapacity {
    /// Columns for a dock grid: one per `cellWidth` it has, but never fewer than `atLeast`, which is what an ordinary phone shows today.
    public static func columns(gridWidth: CGFloat, cellWidth: CGFloat, atLeast: Int) -> Int {
        guard cellWidth > 0, gridWidth.isFinite, gridWidth > 0 else { return atLeast }
        return max(atLeast, Int(gridWidth / cellWidth))
    }

    /// Whole buttons a column of this height holds, between its own top and bottom padding.
    public static func rows(height: CGFloat, buttonHeight: CGFloat, gap: CGFloat, padding: CGFloat) -> Int {
        let room = height - 2 * padding + gap
        guard buttonHeight > 0, room > 0 else { return 0 }
        return Int(room / (buttonHeight + gap))
    }

    /// How many of a rail's optional groups fit after its fixed first `fixed` buttons, each group given as its size. Groups are taken in order and a group that does not fit whole stops the list, except the first optional group, which may be cut short.
    public static func optionalCounts(capacity: Int, fixed: Int, groups: [Int]) -> [Int] {
        var remaining = max(0, capacity - fixed)
        var counts: [Int] = []
        for (index, size) in groups.enumerated() {
            let shown: Int
            if size <= remaining {
                shown = size
            } else if index == 0 {
                shown = remaining
            } else {
                shown = 0
            }
            counts.append(shown)
            remaining -= shown
            if shown < size { remaining = 0 }
        }
        return counts
    }
}
