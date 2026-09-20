//
//  SessionRecordTests.swift
//  MacCastKitTests
//

import XCTest
@testable import MacCastKit

/// What a session leaves behind, and what the allowance makes of it.
///
/// **The two rules Stage 1 moved here, and the reason they moved rather than being tested through
/// the app.** Both are arithmetic over a session's own facts — which path it took, how long it was
/// up — and both were previously written where nothing could run them: the app target cannot run
/// its test action at all under this toolchain, so a rule that stays in `SessionModel` is a rule
/// nobody checks. See `AGENTS.md`.
///
/// The second of the two is the one with a real defect behind it. The allowance used to add the
/// single session the app considered live, which was correct only for as long as there could be
/// exactly one. Two Macs on the relay and the meter under-reports by the Mac nobody was looking
/// at, and the user is cut off before the bar says they should be.
final class SessionRecordTests: XCTestCase {

    // MARK: - Filing a session under the path it took

    /// Each path files under its own spelling, in the record's own words.
    func testEachPathFilesUnderItsOwnRecordSpelling() {
        XCTAssertEqual(ConnectionPath.lan.recordPath, .lan)
        XCTAssertEqual(ConnectionPath.relay.recordPath, .relay)
        XCTAssertEqual(ConnectionPath.direct.recordPath, .direct)
    }

    /// **A session with no path is not a relayed one.** Filing it as relayed would spend the
    /// user's allowance on a connection the relay never spliced.
    func testASessionWithNoPathIsFiledAsLocal() {
        XCTAssertEqual(ConnectionPath.recordPath(of: nil), .lan)
    }

    /// The mapping is total over the cases, so a case added later cannot fall through silently.
    func testEveryCaseHasARecordSpelling() {
        for path in ConnectionPath.allCases {
            // The same three cases, and the record spells each of them differently from the
            // panel: "Relay" beside a date, "RELAY" on a diagnostics line.
            XCTAssertEqual(path.recordPath.rawValue.lowercased(), path.rawValue.lowercased())
        }
    }

    // MARK: - Summing the allowance

    func testRelayTimeSumsEveryFinishedRelayRecord() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let used = RelayAllowance.secondsUsed(
            records: [
                record(path: .relay, startedAt: start, duration: 600),
                record(path: .relay, startedAt: start, duration: 300),
            ],
            windowStart: start,
            liveRelaySeconds: []
        )
        XCTAssertEqual(used, 900)
    }

    /// **The defect this rule exists for.** Both live sessions are on the relay, so both are
    /// being charged for, and a meter that counted one of them would say 600 where the answer
    /// is 900.
    func testRelayTimeSumsEveryLiveSessionAndNotJustOne() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let used = RelayAllowance.secondsUsed(
            records: [],
            windowStart: start,
            liveRelaySeconds: [600, 300]
        )
        XCTAssertEqual(used, 900)
    }

    /// A session over the LAN spends nothing, and neither does one that took a direct path:
    /// the relay is not splicing either of them.
    func testLocalSessionsSpendNothing() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let used = RelayAllowance.secondsUsed(
            records: [record(path: .lan, startedAt: start, duration: 600)],
            windowStart: start,
            liveRelaySeconds: []
        )
        XCTAssertEqual(used, 0)
    }

    /// A record from before the window began belongs to the previous one, which the relay has
    /// already forgotten.
    func testRecordsFromAnEarlierWindowAreNotCounted() {
        let windowStart = Date(timeIntervalSince1970: 1_000_000)
        let used = RelayAllowance.secondsUsed(
            records: [record(path: .relay, startedAt: windowStart.addingTimeInterval(-60), duration: 600)],
            windowStart: windowStart,
            liveRelaySeconds: []
        )
        XCTAssertEqual(used, 0)
    }

    func testRemainingIsTheAllowanceLessEverythingRelayed() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let remaining = RelayAllowance.secondsRemaining(
            allowance: 1800,
            records: [record(path: .relay, startedAt: start, duration: 600)],
            windowStart: start,
            liveRelaySeconds: [300]
        )
        XCTAssertEqual(remaining, 900)
    }

    /// Spent past the allowance reads as nothing left rather than as a negative number of
    /// seconds, which would draw a bar running backwards.
    func testRemainingNeverGoesNegative() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let remaining = RelayAllowance.secondsRemaining(
            allowance: 1800,
            records: [record(path: .relay, startedAt: start, duration: 2000)],
            windowStart: start,
            liveRelaySeconds: []
        )
        XCTAssertEqual(remaining, 0)
    }

    /// A plan with no allowance has no figure to draw, which is not the same as one with none left.
    func testAnUnlimitedPlanHasNoRemainingFigure() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let remaining = RelayAllowance.secondsRemaining(
            allowance: nil,
            records: [],
            windowStart: start,
            liveRelaySeconds: [600]
        )
        XCTAssertNil(remaining)
    }

    // MARK: - The window

    /// The window is the relay's arithmetic and not a calendar's: epoch days, so the meter and
    /// the server's own counter turn over at the same instant wherever the phone is.
    func testTheWindowIsEpochDays() {
        let windowNumber = RelayAllowance.windowNumber(at: Date(timeIntervalSince1970: 86_400 * 20_000 + 5))
        XCTAssertEqual(windowNumber, 20_000)

        XCTAssertEqual(
            RelayAllowance.windowStart(windowNumber: 20_000),
            Date(timeIntervalSince1970: 86_400 * 20_000)
        )
    }

    // MARK: - Helpers

    private func record(
        path: ClientSessionRecord.Path,
        startedAt: Date,
        duration: TimeInterval
    ) -> ClientSessionRecord {
        ClientSessionRecord(
            id: UUID(),
            hostID: "A1B2C3",
            hostName: "A Mac",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            path: path,
            videoBytesReceived: 0,
            logs: []
        )
    }
}
