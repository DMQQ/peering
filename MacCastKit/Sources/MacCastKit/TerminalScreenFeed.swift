import Foundation
import RemoteCore

/// One terminal's screen, kept in step with the bytes it has already been given.
///
/// The render used to build the screen from the whole session on every frame, which makes it a pure
/// function of the bytes and is only valid while the grid holds still. It does not hold still: the
/// log's height moves for the keyboard and for the history strip, and rotation moves both. Applying
/// the whole session at a new shape re-lays every frame a program ever drew onto a grid it was not
/// addressed to, and a program that repaints is where that is visible as a windowful of
/// half-overwritten lines.
///
/// So the screen is kept and fed only what is new, and a change of shape is a ``TerminalScreen/resize(columns:rows:)``
/// rather than a replay. That is what a real terminal does, and it is why this is a class: the
/// thing being kept is state that outlives one render.
///
/// One of these belongs to each terminal, and its owner is whoever holds that terminal's output.
public final class TerminalScreenFeed {
    private var screen: TerminalScreen?
    /// How much of the buffer has been applied. The buffer is append-only from this end's point of
    /// view, so this is all that is needed to know what is new.
    private var consumed = 0

    public init() {}

    /// The screen for this buffer, having applied whatever of it has not been applied yet.
    public func screen(for output: Data, columns: Int, rows: Int) -> TerminalScreen {
        guard let current = screen, consumed <= output.count else {
            // The first call, or a history that has been trimmed past what was applied: the bytes
            // that made the screen are gone, so it cannot be caught up incrementally. Rebuilding
            // from what is left costs one frame that re-lays the past, which is a great deal better
            // than a screen that is wrong from here on.
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
