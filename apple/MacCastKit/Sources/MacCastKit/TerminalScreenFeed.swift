import Foundation
import RemoteCore

/// Fed only what is new; a change of shape is a ``TerminalScreen/resize(columns:rows:)``, not a replay, which would re-lay every frame onto a grid it was not addressed to. A class because the screen outlives a render.
public final class TerminalScreenFeed {
    private var screen: TerminalScreen?
    private var consumed = 0

    public init() {}

    /// The offset only counts while the buffer grows at the back, so a caller that trims the front has to say so or the screen stops advancing.
    public func discardFront(_ count: Int) {
        guard count > 0 else { return }
        consumed = max(0, consumed - count)
    }

    public func screen(for output: Data, columns: Int, rows: Int) -> TerminalScreen {
        guard let current = screen, consumed <= output.count else {
            // The first call, or a history trimmed past what was applied: the bytes that made the
            // screen are gone, so it cannot be caught up incrementally and has to be rebuilt. One
            // frame that re-lays the past is better than a screen that is wrong from here on.
            var fresh = TerminalScreen(columns: columns, rows: rows)
            fresh.feed(output)
            screen = fresh
            consumed = output.count
            return fresh
        }

        var kept = current
        if kept.columns != columns || kept.rows != rows {
            kept.resize(columns: columns, rows: rows)
        }
        if consumed < output.count {
            // Sliced in the buffer's own index space. `Data` answers `removeFirst` by moving its
            // start index rather than by compacting, so a buffer that has lost bytes off the front
            // is not zero-based and a plain `output[consumed...]` is out of range.
            kept.feed(output[(output.startIndex + consumed)...])
            consumed = output.count
        }
        screen = kept
        return kept
    }
}
