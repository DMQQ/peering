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
    /// How much of the buffer has been applied. Append-only from this end, so a count is enough.
    private var consumed = 0

    public init() {}

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
            kept.feed(output[consumed...])
            consumed = output.count
        }
        screen = kept
        return kept
    }
}
