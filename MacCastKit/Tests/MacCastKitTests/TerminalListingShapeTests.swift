import RemoteCore
import XCTest
@testable import MacCastKit

/// What listing the Mac's sessions has to leave alone.
///
/// Opening the panel lists them, and the Mac answers each one with its whole history, which is
/// replayed here onto a screen built fresh. Those bytes were drawn for exactly one grid, the one
/// the shell was last told it has, so the shape is the one thing a listing must not reset. Reset
/// to the 80×24 default, every frame of a full-screen program is laid out wrapped and clipped, and
/// the resize the panel sends a moment later only truncates and pads: the picture never comes back.
///
/// Taken from a traced session off the phone, where reopening a terminal that was drawn correctly
/// came back as fragments.
final class TerminalListingShapeTests: XCTestCase {
    private let id = UUID(uuidString: "1E1C6C7E-2E4A-4E1C-9F1E-6C7E2E4A4E1C")!

    private func text(of screen: TerminalScreen) -> String {
        screen.styled
            .dropFirst(screen.scrollback.count)
            .map { $0.runs.map(\.text).joined() }
            .joined(separator: "\n")
    }

    /// A frame of the kind a full-screen program draws: a rule as wide as the screen, a line under
    /// it, and a status line the program places by addressing it.
    private func frame(columns: Int) -> Data {
        var bytes = Data()
        bytes.append(Data("\u{1b}[2J\u{1b}[H".utf8))
        bytes.append(Data(String(repeating: "\u{2500}", count: columns).utf8))
        bytes.append(Data("\r\nClaude Code v2.1.289\r\n".utf8))
        bytes.append(Data("\u{1b}[10;1H\u{1b}[2K  \u{23f5}\u{23f5} auto mode on".utf8))
        return bytes
    }

    private func terminal(columns: Int, rows: Int) -> RemoteTerminal {
        var terminal = RemoteTerminal(id: id, name: "Claude", isRunning: true)
        terminal.columns = columns
        terminal.rows = rows
        return terminal
    }

    func testAListingKeepsTheShapeTheScreenAlreadyIs() {
        let listed = RemoteTerminal.from(
            [TerminalSessionInfo(id: id, name: "Claude", isRunning: true)],
            remembering: [terminal(columns: 102, rows: 66)]
        )

        XCTAssertEqual(listed[0].columns, 102)
        XCTAssertEqual(listed[0].rows, 66)
        XCTAssertTrue(listed[0].output.isEmpty, "the replay that follows is what fills it")
    }

    func testAListingTakesTheShapeTheMacReports() {
        let listed = RemoteTerminal.from(
            [TerminalSessionInfo(id: id, name: "Claude", isRunning: true, columns: 100, rows: 30)],
            remembering: [terminal(columns: 80, rows: 24)]
        )

        XCTAssertEqual(listed[0].columns, 100, "what the Mac says its shell is outranks a default")
        XCTAssertEqual(listed[0].rows, 30)
    }

    func testAReplayedSessionIsLaidOutOnTheShapeItWasDrawnFor() {
        let drawn = frame(columns: 102)

        let live = TerminalScreenFeed()
        let before = text(of: live.screen(for: drawn, columns: 102, rows: 66))
        XCTAssertTrue(before.contains("auto mode"), "the frame is one a program drew")

        // The reopen: a screen built fresh for the listing's replay, on the shape the listing kept.
        let listed = RemoteTerminal.from(
            [TerminalSessionInfo(id: id, name: "Claude", isRunning: true)],
            remembering: [terminal(columns: 102, rows: 66)]
        )[0]
        let after = text(of: listed.screenFeed.screen(for: drawn, columns: listed.columns, rows: listed.rows))

        XCTAssertEqual(after, before)
    }

    /// The shape is load-bearing, which is why the listing keeps it: the same replay on the default
    /// grid is a different screen, and the resize that follows does not undo it.
    func testAReplayOnTheDefaultGridIsNotTheScreenItWas() {
        let drawn = frame(columns: 102)

        var atTheRightShape = TerminalScreen(columns: 102, rows: 66)
        atTheRightShape.feed(drawn)

        let feed = TerminalScreenFeed()
        _ = feed.screen(for: drawn, columns: 80, rows: 24)
        let resized = feed.screen(for: drawn, columns: 102, rows: 66)

        XCTAssertNotEqual(text(of: resized), text(of: atTheRightShape))
    }
}
