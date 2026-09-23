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
    /// The size both logs are set in unless the user has said otherwise. Every number below is
    /// this one unless it says which size it is about.
    private let regular = TerminalMetrics.TextSize.regular.points

    /// A portrait phone, which is the case the floor exists for: the log measures about thirty-six
    /// hundredths of a point per column, so it would otherwise ask for fifty.
    func testNarrowLogIsWidenedToTheFloor() {
        XCTAssertEqual(TerminalMetrics.columns(forWidth: 360, fontSize: regular), 80)
    }

    /// Past the floor the measurement is the answer, and it is the whole part of it: a column the
    /// log cannot draw the last of is a column the shell would not fill.
    func testWideLogKeepsEveryColumnItFits() {
        XCTAssertEqual(TerminalMetrics.columns(forWidth: 1200, fontSize: regular), 166)
    }

    /// Rows have a floor of their own, and it is a much lower one: only a keyboard covering most of
    /// the screen reaches it, and the panel that did would still need a shell that runs.
    func testRowsAreFlooredToo() {
        XCTAssertEqual(TerminalMetrics.rows(forHeight: 40, fontSize: regular), 6)
        XCTAssertEqual(TerminalMetrics.rows(forHeight: 288, fontSize: regular), 20)
    }

    /// **The size is the dial for how much of a shell fits across a phone.** The shell is still
    /// told eighty columns, because that is what a full-screen program lays its boxes out for; what
    /// the size changes is how many of those eighty are on the screen instead of off its edge.
    ///
    /// Measured on a log wide enough for the floor not to be the answer, which is the only place
    /// the arithmetic is visible: a portrait phone is under it at every size, which is exactly why
    /// the right-hand third of a line needs dragging into view there.
    func testSmallerTextFitsMoreColumns() {
        let small = TerminalMetrics.TextSize.small.points
        let large = TerminalMetrics.TextSize.large.points
        let wide = CGFloat(900)

        XCTAssertEqual(TerminalMetrics.columns(forWidth: wide, fontSize: small), 166)
        XCTAssertEqual(TerminalMetrics.columns(forWidth: wide, fontSize: large), 100)
        XCTAssertTrue(
            TerminalMetrics.cellWidth(for: small) < TerminalMetrics.cellWidth(for: large),
            "a smaller size is a narrower cell, which is what puts more columns on the screen"
        )
    }
}
