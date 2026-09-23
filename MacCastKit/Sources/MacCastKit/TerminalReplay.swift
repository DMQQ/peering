import Foundation
import RemoteCore

/// A session's bytes, replayed onto the grid they are being drawn on.
///
/// Both terminals draw by handing ``TerminalScreen`` everything the shell has ever sent, which is
/// what makes the render a pure function of the bytes and the screen cheap to rebuild. That is
/// only true of a *fixed grid*: a byte stream is a picture of a screen at the size it was written
/// for, because a program addresses cells by row and column and counts lines to move its cursor.
/// Replaying what it drew for one shape onto another lands every frame where the program did not
/// put it, over the frame before it, and what the user sees is a smear of half-overwritten lines
/// that gets worse the longer a full-screen program keeps painting.
///
/// So the resize is recorded, and the replay puts the old screen down where it happened. Nothing
/// visible is lost by that: the far end is told about the resize and redraws its whole frame, so
/// everything before the mark belongs to a screen that no longer exists.
public enum TerminalReplay {
    /// What those bytes draw, cleared wherever the grid changed shape.
    ///
    /// - Parameter clearedAt: one byte offset per geometry change, into the same buffer.
    public static func screen(
        _ bytes: Data,
        columns: Int,
        rows: Int,
        clearedAt marks: [Int] = []
    ) -> TerminalScreen {
        var screen = TerminalScreen(columns: columns, rows: rows)
        var cursor = bytes.startIndex
        // A mark past the end of what is held is one left behind by a trimmed history, and skipping
        // it costs one clear in the wrong place rather than a wrong screen.
        for mark in marks.sorted() where mark > cursor && mark <= bytes.endIndex {
            screen.feed(bytes[cursor..<mark])
            screen.feed(Self.clear)
            cursor = mark
        }
        screen.feed(bytes[cursor...])
        return screen
    }

    /// Erase the display: what a program sends to start a frame from nothing.
    private static let clear = Data("\u{1B}[2J".utf8)
}
