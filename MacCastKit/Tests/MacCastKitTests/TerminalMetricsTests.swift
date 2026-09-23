import XCTest
@testable import MacCastKit

/// The arithmetic between the log on screen and the size the shell is told it is.
///
/// Worth asserting because both ends of it fail quietly. A shell told it is fifty columns wide
/// wraps before a full-screen program's boxes are drawn, which reads as that program being broken
/// rather than as this side having asked for the wrong size; a shell told it is wider than the log
/// can draw loses the right of every line, which reads as the log being broken. Both are numbers
/// rather than errors, which is why they are checked here.
final class TerminalMetricsTests: XCTestCase {
    /// A portrait phone, which is the case the floor exists for: the log measures about thirty-six
    /// hundredths of a point per column, so it would otherwise ask for fifty.
    func testNarrowLogIsWidenedToTheFloor() {
        XCTAssertEqual(TerminalMetrics.columns(forWidth: 360), 80)
    }

    /// Past the floor the measurement is the answer, and it is the whole part of it: a column the
    /// log cannot draw the last of is a column the shell would not fill.
    func testWideLogKeepsEveryColumnItFits() {
        XCTAssertEqual(TerminalMetrics.columns(forWidth: 1200), 166)
    }

    /// Rows have a floor of their own, and it is a much lower one: only a keyboard covering most of
    /// the screen reaches it, and the panel that did would still need a shell that runs.
    func testRowsAreFlooredToo() {
        XCTAssertEqual(TerminalMetrics.rows(forHeight: 40), 6)
        XCTAssertEqual(TerminalMetrics.rows(forHeight: 288), 20)
    }
}
