import Foundation
import RemoteCore

/// One terminal's screen, kept in step with the bytes it has already been given.
///
/// The screen is kept and fed only what is new, and a change of shape is a
/// ``TerminalScreen/resize(columns:rows:)`` rather than a replay: replaying the session onto a new
/// grid re-lays every frame a program ever drew onto a grid it was not addressed to. It is a class
/// because the kept screen is state that outlives one render.
public final class TerminalScreenFeed {
    private var screen: TerminalScreen?
    /// How much of the buffer has been applied, as an offset into the buffer as it stands now.
    private var consumed = 0

    public init() {}

    /// Says that the buffer this feed was last given has lost bytes off its front.
    ///
    /// The offset below only counts while the buffer grows at the back and nowhere else, so a caller
    /// that trims its own copy from the front has to say so or the screen stops advancing.
    public func discardFront(_ count: Int) {
        guard count > 0 else { return }
        consumed = max(0, consumed - count)
    }

    /// The screen for this buffer, having applied whatever of it has not been applied yet.
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
