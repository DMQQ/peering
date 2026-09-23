import RemoteCore
import XCTest
@testable import MacCastKit

/// What a terminal that is fed rather than replayed has to get right.
///
/// The screen used to be rebuilt from the whole session on every render. That is only valid at one
/// shape, and the log's shape moves for the keyboard, for the history strip and for a rotation, so
/// the case these cover is the one that was wrong: bytes arriving across a change of shape, which
/// has to leave what a program already drew where it drew it.
final class TerminalScreenFeedTests: XCTestCase {
    private func text(of screen: TerminalScreen) -> String {
        screen.styled
            .dropFirst(screen.scrollback.count)
            .map { $0.runs.map(\.text).joined() }
            .joined(separator: "\n")
    }

    /// The property the old design had for free and this one has to keep: the same bytes are the
    /// same screen, however they are cut up.
    func testBytesArrivingInPiecesAreTheSameScreen() {
        let all = Data("one\r\ntwo\r\nthree\r\n".utf8)
        let piece = all.count / 2

        let feed = TerminalScreenFeed()
        _ = feed.screen(for: Data(all.prefix(piece)), columns: 20, rows: 6)
        let inPieces = feed.screen(for: all, columns: 20, rows: 6)

        var atOnce = TerminalScreen(columns: 20, rows: 6)
        atOnce.feed(all)

        XCTAssertEqual(text(of: inPieces), text(of: atOnce))
    }

    /// The fault this exists for: a program's frame is drawn where the program put it, and a change
    /// of shape does not re-lay it.
    func testAFrameSurvivesAResizeWhereItWasDrawn() {
        let feed = TerminalScreenFeed()
        let frame = Data("top\r\nmiddle\r\nbottom\r\n".utf8)
        let before = text(of: feed.screen(for: frame, columns: 20, rows: 6))

        // The log grows: the keyboard goes away.
        let after = text(of: feed.screen(for: frame, columns: 20, rows: 12))

        XCTAssertEqual(before, after, "the rows are the rows the program drew, at either shape")
        XCTAssertTrue(after.contains("middle"))
    }

    /// And bytes that arrive after a resize are applied to the screen that is there, rather than to
    /// a fresh one built at the new shape.
    func testBytesAfterAResizeAreAppliedToTheScreenThatIsThere() {
        let feed = TerminalScreenFeed()
        var bytes = Data("first\r\n".utf8)
        _ = feed.screen(for: bytes, columns: 20, rows: 4)

        // The grid changes shape, then the program draws its next line.
        _ = feed.screen(for: bytes, columns: 20, rows: 8)
        bytes.append(Data("second\r\n".utf8))
        let screen = feed.screen(for: bytes, columns: 20, rows: 8)

        XCTAssertTrue(text(of: screen).contains("first"), "what was drawn before the resize is still there")
        XCTAssertTrue(text(of: screen).contains("second"))
    }

    /// The half of a resize a program actually feels: a shorter screen keeps the cursor on it, by
    /// moving the rows up, so the write it makes next lands where it believes the cursor is.
    ///
    /// This is the keyboard. Opening it shortens the log, which shortens the shell's screen, and a
    /// terminal that dropped the rows under the cursor instead of scrolling would leave every
    /// repaint after that drawn a line or two from where the program put it.
    func testAShorterScreenScrollsTheCursorBackIntoView() {
        let feed = TerminalScreenFeed()
        let drawn = Data("aa\r\nbb\r\ncc\r\ndd\r\nee\r\nf".utf8)
        let tall = feed.screen(for: drawn, columns: 20, rows: 6)
        XCTAssertTrue(text(of: tall).contains("aa"), "the whole frame fits on the tall screen")

        let short = feed.screen(for: drawn, columns: 20, rows: 4)
        XCTAssertFalse(text(of: short).contains("aa"), "the rows that do not fit have gone")
        XCTAssertTrue(text(of: short).contains("cc"), "and what was under them has moved up")

        // The program writes where it believes the cursor is, which is just past the `f`.
        var more = drawn
        more.append(Data("X".utf8))
        let written = feed.screen(for: more, columns: 20, rows: 4)
        XCTAssertTrue(text(of: written).contains("fX"), "the next write lands beside what was written before it")
    }

    /// A history trimmed past what has been applied cannot be caught up from, and rebuilding is the
    /// answer rather than a screen that is wrong from then on.
    func testATrimmedHistoryIsRebuilt() {
        let feed = TerminalScreenFeed()
        var bytes = Data("gone one\r\ngone two\r\n".utf8)
        _ = feed.screen(for: bytes, columns: 20, rows: 4)

        // The model drops the front of the buffer, which is what its own limit does, and what is
        // left is shorter than what was applied.
        bytes = Data("kept\r\n".utf8)
        let screen = feed.screen(for: bytes, columns: 20, rows: 4)

        XCTAssertTrue(text(of: screen).contains("kept"))
        XCTAssertFalse(text(of: screen).contains("gone"), "the bytes that drew it are not in the buffer any more")
    }
}
