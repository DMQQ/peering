import RemoteCore
import XCTest
@testable import MacCastKit

/// The property a terminal that streams a full-screen program depends on.
///
/// The render is a replay of everything the shell has ever sent, and a byte stream only addresses
/// the grid it was written for. These assert both halves of that: the replay is exactly the last
/// frame while the grid holds still, and it is not once the grid has changed shape unless the
/// change was marked.
final class TerminalReplayTests: XCTestCase {
    /// One frame of a program that draws in place: four rows, then the cursor back up to the top
    /// left, the way a full-screen program leaves itself for the next frame.
    private func frame(_ text: [String], rows: Int) -> Data {
        var bytes = Data()
        for line in text { bytes.append(Data((line + "\r\n").utf8)) }
        // Back up to the row the frame started on, which is a relative move: what it lands on
        // depends on how many rows the screen has, and that is the whole reason a replay cannot
        // survive a resize.
        bytes.append(Data("\u{1B}[\(rows)A\r".utf8))
        return bytes
    }

    private func text(of screen: TerminalScreen) -> String {
        screen.styled
            .map { $0.runs.map(\.text).joined() }
            .joined(separator: "\n")
    }

    /// What is on the screen, as opposed to what has scrolled off it. A row that scrolled away is
    /// scrollback and belongs there whatever shape the grid is; the fault is rows still being
    /// *drawn* on a screen that has finished with them.
    private func onScreen(_ screen: TerminalScreen) -> String {
        screen.styled
            .dropFirst(screen.scrollback.count)
            .map { $0.runs.map(\.text).joined() }
            .joined(separator: "\n")
    }

    /// The ordinary case, which is what the type promises: the grid has not moved, so the replay
    /// is the last frame and nothing else.
    func testAFixedGridReplaysAsTheLastFrame() {
        var bytes = frame(["AAAA", "BBBB", "CCCC", "DDDD"], rows: 4)
        let reset: [Int] = []
        bytes.append(frame(["EEEE", "FFFF", "GGGG", "HHHH"], rows: 4))

        let screen = TerminalReplay.screen(bytes, columns: 20, rows: 6, clearedAt: reset)
        let drawn = text(of: screen)

        XCTAssertTrue(drawn.contains("EEEE"))
        XCTAssertFalse(drawn.contains("AAAA"))
    }

    /// The fault this exists for, in the shape of it that needs no particular program: rows that
    /// scrolled off a short screen are still on a tall one.
    ///
    /// This is the half of a resize that a replay cannot get right by itself. A frame written for a
    /// screen with fewer rows scrolls, and the same bytes replayed onto a taller screen do not, so
    /// rows the program has finished with are drawn as if they were still current, and everything
    /// it paints after them lands against a screen it does not believe it has. Clearing at the mark
    /// is what makes the two agree.
    func testRowsThatScrolledOffAShortScreenAreNotOnATallOne() {
        var bytes = frame(["AAAA", "BBBB", "CCCC", "DDDD", "EEEE", "FFFF"], rows: 4)
        let mark = bytes.count
        bytes.append(frame(["GGGG", "HHHH"], rows: 4))

        // A six-line frame on a four-row screen scrolls two rows further than the same frame on a
        // six-row one, so `BBBB` has left a four-row screen and is still on a six-row one.
        let unmarked = onScreen(TerminalReplay.screen(bytes, columns: 20, rows: 6))
        XCTAssertTrue(unmarked.contains("BBBB"), "a row the program has scrolled past is still on this screen")

        let marked = onScreen(TerminalReplay.screen(bytes, columns: 20, rows: 6, clearedAt: [mark]))
        XCTAssertTrue(marked.contains("GGGG"), "the frame drawn after the resize is what is on the screen")
        XCTAssertFalse(marked.contains("BBBB"), "the marked resize starts from the frame the program redrew")
    }

    /// And a mark from a history that has since been trimmed is skipped rather than misapplied.
    func testAMarkPastTheEndIsIgnored() {
        let bytes = frame(["EEEE", "FFFF"], rows: 2)
        let screen = TerminalReplay.screen(bytes, columns: 20, rows: 6, clearedAt: [9_999])
        XCTAssertTrue(text(of: screen).contains("EEEE"))
    }
}
