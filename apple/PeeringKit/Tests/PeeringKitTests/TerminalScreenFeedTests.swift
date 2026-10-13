import RemoteCore
import XCTest
@testable import PeeringKit

/// The screen is fed rather than rebuilt, so bytes arriving across a change of shape must leave what a program drew where it drew it.
final class TerminalScreenFeedTests: XCTestCase {
    private func text(of screen: TerminalScreen) -> String {
        screen.styled
            .dropFirst(screen.scrollback.count)
            .map { $0.runs.map(\.text).joined() }
            .joined(separator: "\n")
    }

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

    func testAFrameSurvivesAResizeWhereItWasDrawn() {
        let feed = TerminalScreenFeed()
        let frame = Data("top\r\nmiddle\r\nbottom\r\n".utf8)
        let before = text(of: feed.screen(for: frame, columns: 20, rows: 6))

        let after = text(of: feed.screen(for: frame, columns: 20, rows: 12))

        XCTAssertEqual(before, after, "the rows are the rows the program drew, at either shape")
        XCTAssertTrue(after.contains("middle"))
    }

    func testBytesAfterAResizeAreAppliedToTheScreenThatIsThere() {
        let feed = TerminalScreenFeed()
        var bytes = Data("first\r\n".utf8)
        _ = feed.screen(for: bytes, columns: 20, rows: 4)

        _ = feed.screen(for: bytes, columns: 20, rows: 8)
        bytes.append(Data("second\r\n".utf8))
        let screen = feed.screen(for: bytes, columns: 20, rows: 8)

        XCTAssertTrue(text(of: screen).contains("first"), "what was drawn before the resize is still there")
        XCTAssertTrue(text(of: screen).contains("second"))
    }

    /// A shorter screen keeps the cursor on it by moving rows up; dropping the rows under it misplaces every repaint (the keyboard case).
    func testAShorterScreenScrollsTheCursorBackIntoView() {
        let feed = TerminalScreenFeed()
        let drawn = Data("aa\r\nbb\r\ncc\r\ndd\r\nee\r\nf".utf8)
        let tall = feed.screen(for: drawn, columns: 20, rows: 6)
        XCTAssertTrue(text(of: tall).contains("aa"), "the whole frame fits on the tall screen")

        let short = feed.screen(for: drawn, columns: 20, rows: 4)
        XCTAssertFalse(text(of: short).contains("aa"), "the rows that do not fit have gone")
        XCTAssertTrue(text(of: short).contains("cc"), "and what was under them has moved up")

        var more = drawn
        more.append(Data("X".utf8))
        let written = feed.screen(for: more, columns: 20, rows: 4)
        XCTAssertTrue(text(of: written).contains("fX"), "the next write lands beside what was written before it")
    }

    /// A history trimmed past what was applied cannot be caught up from; rebuild.
    func testATrimmedHistoryIsRebuilt() {
        let feed = TerminalScreenFeed()
        var bytes = Data("gone one\r\ngone two\r\n".utf8)
        _ = feed.screen(for: bytes, columns: 20, rows: 4)

        bytes = Data("kept\r\n".utf8)
        let screen = feed.screen(for: bytes, columns: 20, rows: 4)

        XCTAssertTrue(text(of: screen).contains("kept"))
        XCTAssertFalse(text(of: screen).contains("gone"), "the bytes that drew it are not in the buffer any more")
    }

    /// A trim to exactly the length the feed last read at must not stop the feed advancing.
    func testABufferTrimmedToTheLengthItWasReadAtKeepsFeeding() {
        let feed = TerminalScreenFeed()
        var bytes = Data("one\r\n".utf8)
        let limit = bytes.count

        _ = feed.screen(for: bytes, columns: 20, rows: 4)

        bytes.append(Data("two\r\n".utf8))
        let dropped = bytes.count - limit
        bytes.removeFirst(dropped)
        feed.discardFront(dropped)

        let screen = feed.screen(for: bytes, columns: 20, rows: 4)
        XCTAssertTrue(text(of: screen).contains("two"), "the chunk that arrived after the trim is on the screen")
    }

    /// Repeated trim via removeFirst: the feed must slice in the buffer's own index space, not from zero.
    func testEveryTrimAfterTheFirstStillFeeds() {
        func line(_ index: Int) -> Data {
            Data(String(format: "line %03d\r\n", index).utf8)
        }

        let feed = TerminalScreenFeed()
        var bytes = line(0)
        bytes.append(line(1))
        let limit = bytes.count
        _ = feed.screen(for: bytes, columns: 20, rows: 4)

        for index in 2..<6 {
            bytes.append(line(index))
            let dropped = bytes.count - limit
            bytes.removeFirst(dropped)
            feed.discardFront(dropped)
            _ = feed.screen(for: bytes, columns: 20, rows: 4)
        }

        let screen = feed.screen(for: bytes, columns: 20, rows: 4)
        XCTAssertTrue(text(of: screen).contains("line 005"), "the screen followed every trim, not only the first")
    }

    func testABufferRebuiltFromItsTailKeepsFeeding() {
        func line(_ index: Int) -> Data {
            Data(String(format: "line %03d\r\n", index).utf8)
        }

        let feed = TerminalScreenFeed()
        var bytes = line(0)
        bytes.append(line(1))
        let limit = bytes.count
        _ = feed.screen(for: bytes, columns: 20, rows: 4)

        for index in 2..<6 {
            bytes.append(line(index))
            let dropped = bytes.count - limit
            bytes = Data(bytes.dropFirst(dropped))
            feed.discardFront(dropped)
            _ = feed.screen(for: bytes, columns: 20, rows: 4)
        }

        let screen = feed.screen(for: bytes, columns: 20, rows: 4)
        XCTAssertTrue(text(of: screen).contains("line 005"), "the last line through the rebuilt buffer is on the screen")
    }
}
