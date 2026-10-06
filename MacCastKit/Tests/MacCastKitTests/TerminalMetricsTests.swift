import XCTest
@testable import MacCastKit

/// Both ends fail quietly (too narrow wraps full-screen programs, too wide loses the right of each line), so the arithmetic is asserted.
final class TerminalMetricsTests: XCTestCase {
    private let regular = TerminalMetrics.TextSize.regular.points

    /// A portrait phone is the case the floor exists for: it would otherwise ask for fifty columns.
    func testNarrowLogIsWidenedToTheFloor() {
        XCTAssertEqual(TerminalMetrics.columns(forWidth: 360, fontSize: regular), 80)
    }

    func testWideLogKeepsEveryColumnItFits() {
        XCTAssertEqual(TerminalMetrics.columns(forWidth: 1200, fontSize: regular), 166)
    }

    func testRowsAreFlooredToo() {
        XCTAssertEqual(TerminalMetrics.rows(forHeight: 40, fontSize: regular), 6)
        XCTAssertEqual(TerminalMetrics.rows(forHeight: 288, fontSize: regular), 20)
    }

    /// The size sets how many of the eighty columns fit on screen; the shell is still told eighty.
    /// Measured on a log wide enough for the floor not to bind.
    func testSmallerTextFitsMoreColumns() {
        let small = TerminalMetrics.TextSize.small.points
        let large = TerminalMetrics.TextSize.large.points
        let wide = CGFloat(900)

        XCTAssertEqual(
            TerminalMetrics.columns(forWidth: 360, fontSize: TerminalMetrics.TextSize.tiny.points),
            85
        )

        XCTAssertEqual(TerminalMetrics.columns(forWidth: wide, fontSize: small), 166)
        XCTAssertEqual(TerminalMetrics.columns(forWidth: wide, fontSize: large), 100)
        XCTAssertTrue(
            TerminalMetrics.cellWidth(for: small) < TerminalMetrics.cellWidth(for: large),
            "a smaller size is a narrower cell, which is what puts more columns on the screen"
        )
    }
}
