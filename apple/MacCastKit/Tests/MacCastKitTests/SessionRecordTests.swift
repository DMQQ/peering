//
//  SessionRecordTests.swift
//  MacCastKitTests
//

import XCTest
@testable import MacCastKit

/// Session filing and allowance rules, moved out of SessionModel because the app target cannot run its tests (see AGENTS.md).
/// The allowance sums every live relay session, and a session put back after a drop is one row (see ``SessionContinuation``).
final class SessionRecordTests: XCTestCase {

    // MARK: - Filing a session under the path it took

    func testEachPathFilesUnderItsOwnRecordSpelling() {
        XCTAssertEqual(ConnectionPath.lan.recordPath, .lan)
        XCTAssertEqual(ConnectionPath.relay.recordPath, .relay)
        XCTAssertEqual(ConnectionPath.direct.recordPath, .direct)
    }

    /// A session with no path is not a relayed one; filing it so would spend allowance on a splice that never happened.
    func testASessionWithNoPathIsFiledAsLocal() {
        XCTAssertEqual(ConnectionPath.recordPath(of: nil), .lan)
    }

    func testEveryCaseHasARecordSpelling() {
        for path in ConnectionPath.allCases {
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
            liveRelaySegments: []
        )
        XCTAssertEqual(used, 900)
    }

    /// Both live sessions are on the relay, so both are charged: counting one would say 600 where the answer is 900.
    func testRelayTimeSumsEveryLiveSessionAndNotJustOne() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let used = RelayAllowance.secondsUsed(
            records: [],
            windowStart: start,
            liveRelaySegments: [
                DateInterval(start: start, duration: 600),
                DateInterval(start: start, duration: 300),
            ]
        )
        XCTAssertEqual(used, 900)
    }

    /// The gap is not charged: the relay splices none of the time spent backgrounded or retrying.
    func testRelayTimeCountsConnectedSecondsAndNotTheGap() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let used = RelayAllowance.secondsUsed(
            records: [
                record(
                    path: .relay,
                    startedAt: start,
                    duration: 7_200,
                    connectedSegments: [DateInterval(start: start, duration: 600)]
                )
            ],
            windowStart: start,
            liveRelaySegments: []
        )
        XCTAssertEqual(used, 600)
    }

    /// The same sum over a live session, whose stretch is only this segment; the earlier half is already in the history.
    func testALiveSessionAddsOnlyTheSegmentItIsRunning() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let used = RelayAllowance.secondsUsed(
            records: [
                record(
                    path: .relay,
                    startedAt: start,
                    duration: 3_600,
                    connectedSegments: [DateInterval(start: start, duration: 300)]
                )
            ],
            windowStart: start,
            liveRelaySegments: [DateInterval(start: start, duration: 120)]
        )
        XCTAssertEqual(used, 420)
    }

    // MARK: - What a window spends

    /// The relay charges per epoch day, so a session spanning the turnover is charged only for the part inside the window.
    /// Reading the record's start instead loses the whole session.
    func testARecordSpanningTheWindowIsCountedFromItsStart() {
        let windowStart = Date(timeIntervalSince1970: 86_400 * 20_000)
        let used = RelayAllowance.secondsUsed(
            records: [
                record(
                    path: .relay,
                    startedAt: windowStart.addingTimeInterval(-600),
                    duration: 1_800
                )
            ],
            windowStart: windowStart,
            liveRelaySegments: []
        )
        XCTAssertEqual(used, 1_200, "the twenty minutes on this side of the boundary")
    }

    func testARecordThatEndedBeforeTheWindowIsNotCounted() {
        let windowStart = Date(timeIntervalSince1970: 86_400 * 20_000)
        let used = RelayAllowance.secondsUsed(
            records: [
                record(
                    path: .relay,
                    startedAt: windowStart.addingTimeInterval(-1_200),
                    duration: 600
                )
            ],
            windowStart: windowStart,
            liveRelaySegments: []
        )
        XCTAssertEqual(used, 0)
    }

    /// A put-back session: only the second stretch spends today's allowance.
    func testOnlyTheStretchOfAResumedSessionInsideTheWindowIsCounted() {
        let windowStart = Date(timeIntervalSince1970: 86_400 * 20_000)
        let used = RelayAllowance.secondsUsed(
            records: [
                record(
                    path: .relay,
                    startedAt: windowStart.addingTimeInterval(-3_600),
                    duration: 4_800,
                    connectedSegments: [
                        DateInterval(
                            start: windowStart.addingTimeInterval(-3_600),
                            end: windowStart.addingTimeInterval(-3_000)
                        ),
                        DateInterval(
                            start: windowStart.addingTimeInterval(600),
                            end: windowStart.addingTimeInterval(1_200)
                        ),
                    ]
                )
            ],
            windowStart: windowStart,
            liveRelaySegments: []
        )
        XCTAssertEqual(used, 600)
    }

    func testALiveSessionIsCountedFromTheWindowAndNotFromItsStart() {
        let windowStart = Date(timeIntervalSince1970: 86_400 * 20_000)
        let used = RelayAllowance.secondsUsed(
            records: [],
            windowStart: windowStart,
            liveRelaySegments: [
                DateInterval(
                    start: windowStart.addingTimeInterval(-600),
                    end: windowStart.addingTimeInterval(900)
                )
            ]
        )
        XCTAssertEqual(used, 900)
    }

    func testAStretchRunningPastTheWindowIsCountedToTheEndOfIt() {
        let windowStart = Date(timeIntervalSince1970: 86_400 * 20_000)
        let used = RelayAllowance.secondsUsed(
            records: [
                record(path: .relay, startedAt: windowStart, duration: 7 * 86_400)
            ],
            windowStart: windowStart,
            liveRelaySegments: []
        )
        XCTAssertEqual(used, RelayAllowance.windowLength)
    }

    /// LAN and direct sessions spend nothing: the relay is not splicing them.
    func testLocalSessionsSpendNothing() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let used = RelayAllowance.secondsUsed(
            records: [record(path: .lan, startedAt: start, duration: 600)],
            windowStart: start,
            liveRelaySegments: []
        )
        XCTAssertEqual(used, 0)
    }

    func testRemainingIsTheAllowanceLessEverythingRelayed() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let remaining = RelayAllowance.secondsRemaining(
            allowance: 1800,
            records: [record(path: .relay, startedAt: start, duration: 600)],
            windowStart: start,
            liveRelaySegments: [DateInterval(start: start, duration: 300)]
        )
        XCTAssertEqual(remaining, 900)
    }

    /// Overspent reads as nothing left, not a negative bar.
    func testRemainingNeverGoesNegative() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let remaining = RelayAllowance.secondsRemaining(
            allowance: 1800,
            records: [record(path: .relay, startedAt: start, duration: 2000)],
            windowStart: start,
            liveRelaySegments: []
        )
        XCTAssertEqual(remaining, 0)
    }

    func testAnUnlimitedPlanHasNoRemainingFigure() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let remaining = RelayAllowance.secondsRemaining(
            allowance: nil,
            records: [],
            windowStart: start,
            liveRelaySegments: [DateInterval(start: start, duration: 600)]
        )
        XCTAssertNil(remaining)
    }

    // MARK: - Continuing a session across a drop

    func testAResumeContinuesTheRecordTheDropFiled() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let dropped = record(path: .relay, startedAt: start, duration: 300, bytes: 4_096)

        let continuation = SessionContinuation.continued(
            in: [dropped], hostID: "A1B2C3", path: .relay
        )

        XCTAssertEqual(continuation?.id, dropped.id)
        XCTAssertEqual(continuation?.startedAt, dropped.startedAt)
        XCTAssertEqual(continuation?.videoBytesReceived, 4_096)
        XCTAssertEqual(
            continuation?.connectedSegments, dropped.connectedSegments,
            "the stretches it was up for go with the row, so the meter can still place them"
        )
    }

    /// The final record keeps the first record's identity and start, sums bytes and connected time, and spans the gap.
    func testTheRecordFiledForAResumedSessionKeepsItsIdentityAndItsBytesAccumulate() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let dropped = record(path: .relay, startedAt: start, duration: 300, bytes: 4_096)
        let continuation = SessionContinuation.continued(
            in: [dropped], hostID: "A1B2C3", path: .relay
        )

        let segmentStart = start.addingTimeInterval(3 * 3_600)
        let endedAt = segmentStart.addingTimeInterval(600)
        let filed = continuation?.filed(
            endedAt: endedAt,
            segmentStartedAt: segmentStart,
            path: .relay,
            hostID: "A1B2C3",
            hostName: "A Mac",
            segmentBytes: 2_048,
            logs: [],
            usedDirectPath: false,
            endedDeliberately: false
        )

        XCTAssertEqual(filed?.id, dropped.id, "the same row, not a second one")
        XCTAssertEqual(filed?.startedAt, dropped.startedAt, "which started at the first connect")
        XCTAssertEqual(filed?.endedAt, endedAt, "and ended at the last disconnect")
        XCTAssertEqual(filed?.videoBytesReceived, 6_144, "the session's bytes, not this segment's")
        XCTAssertEqual(filed?.connectedSeconds, 900, "ten minutes of the three hours was connected")
        XCTAssertEqual(filed?.duration, 3 * 3_600 + 600, "the gap is in the span, and only there")
        XCTAssertEqual(
            filed?.connectedSegments.count, 2,
            "one stretch per time it was up, and not one covering the gap"
        )
        XCTAssertEqual(
            filed?.connectedSegments.last?.duration, 600,
            "the one that just ended is the ten minutes, timed where it happened"
        )
    }

    /// A session that never dropped files exactly as before.
    func testASessionThatNeverDroppedIsFiledConnectedEndToEnd() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let endedAt = start.addingTimeInterval(600)
        let filed = SessionContinuation(id: UUID(), startedAt: start).filed(
            endedAt: endedAt,
            segmentStartedAt: start,
            path: .lan,
            hostID: "A1B2C3",
            hostName: "A Mac",
            segmentBytes: 100,
            logs: [],
            usedDirectPath: false,
            endedDeliberately: false
        )

        XCTAssertEqual(filed.connectedSeconds, 600)
        XCTAssertEqual(filed.duration, 600)
        XCTAssertEqual(filed.videoBytesReceived, 100)
    }

    /// A deliberately ended session is not continued, or Disconnect then Connect an hour later folds two sessions into one.
    func testARecordTheUserEndedIsNotContinued() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let ended = record(path: .relay, startedAt: start, duration: 300, endedDeliberately: true)

        XCTAssertNil(SessionContinuation.continued(in: [ended], hostID: "A1B2C3", path: .relay))
    }

    /// Only the newest record for the Mac continues; a deliberate end writes a record too.
    func testADeliberateEndStopsTheSearchRatherThanBeingLookedPast() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let dropped = record(path: .relay, startedAt: start, duration: 600)
        let ended = record(
            path: .relay, startedAt: start.addingTimeInterval(3_600), duration: 60,
            endedDeliberately: true
        )

        XCTAssertNil(
            SessionContinuation.continued(in: [ended, dropped], hostID: "A1B2C3", path: .relay)
        )
    }

    func testARecordForAnotherMacIsNotContinued() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let other = record(hostID: "D4E5F6", path: .relay, startedAt: start, duration: 300)

        XCTAssertNil(SessionContinuation.continued(in: [other], hostID: "A1B2C3", path: .relay))
    }

    /// A Mac with no identity continues nothing, or nil == nil matches every unattributed record.
    func testARecordWithNoMacIsNotContinuedByASessionWithNoMac() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let unattributed = record(hostID: nil, path: .relay, startedAt: start, duration: 300)

        XCTAssertNil(SessionContinuation.continued(in: [unattributed], hostID: nil, path: .relay))
    }

    /// A record is metered by path and connected time together; mixing paths would mischarge the relay.
    func testARecordIsNotContinuedOnADifferentPath() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let onTheRelay = record(path: .relay, startedAt: start, duration: 300)

        XCTAssertNil(SessionContinuation.continued(in: [onTheRelay], hostID: "A1B2C3", path: .lan))
        XCTAssertNil(SessionContinuation.continued(in: [onTheRelay], hostID: "A1B2C3", path: .direct))
    }

    /// The punching flag is the whole session's answer: it records how often punching works.
    func testAPunchThatHappenedBeforeTheDropIsCarriedIntoTheRecord() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let dropped = record(path: .relay, startedAt: start, duration: 300, usedDirectPath: true)
        let continuation = SessionContinuation.continued(
            in: [dropped], hostID: "A1B2C3", path: .relay
        )
        let endedAt = start.addingTimeInterval(600)

        let filed = continuation?.filed(
            endedAt: endedAt,
            segmentStartedAt: start.addingTimeInterval(400),
            path: .relay,
            hostID: "A1B2C3",
            hostName: "A Mac",
            segmentBytes: 0,
            logs: [],
            usedDirectPath: false,
            endedDeliberately: false
        )

        XCTAssertEqual(filed?.usedDirectPath, true)
    }

    // MARK: - The two figures a row can show

    /// A never-dropped session was connected for its whole span, so a second figure would be noise.
    func testASessionThatWasNeverInterruptedHasNothingToSay() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let whole = record(path: .relay, startedAt: start, duration: 600)

        XCTAssertEqual(whole.connectedSeconds, whole.duration)
        XCTAssertEqual(whole.disconnectedSeconds, 0)
        XCTAssertFalse(whole.wasInterrupted)
    }

    func testASessionThatWasPutBackShowsBothFigures() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let resumed = record(
            path: .relay,
            startedAt: start,
            duration: 7_200,
            connectedSegments: [DateInterval(start: start, duration: 600)]
        )

        XCTAssertEqual(resumed.connectedSeconds, 600)
        XCTAssertEqual(resumed.disconnectedSeconds, 6_600)
        XCTAssertTrue(resumed.wasInterrupted)
    }

    /// Whole seconds, since that is what the screen prints: a difference the reader cannot see is the same figure twice.
    func testADifferenceTheReaderCannotSeeIsNotShown() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let nearlyWhole = record(
            path: .relay,
            startedAt: start,
            duration: 600,
            connectedSegments: [DateInterval(start: start, duration: 599.6)]
        )

        XCTAssertEqual(
            Int(nearlyWhole.duration.rounded()), Int(nearlyWhole.connectedSeconds.rounded()),
            "which is the whole of the reason"
        )
        XCTAssertFalse(nearlyWhole.wasInterrupted)
    }

    /// A sub-second difference that crosses a printed second is shown; comparing the raw gap would print the same figure twice.
    func testADifferenceThatCrossesAPrintedSecondIsShown() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let halfASecondShort = record(
            path: .relay,
            startedAt: start,
            duration: 600,
            connectedSegments: [DateInterval(start: start, duration: 599.4)]
        )

        XCTAssertTrue(halfASecondShort.wasInterrupted)
    }

    // MARK: - Recent history

    func testRecentHistoryKeepsTwentyFiveSessions() {
        XCTAssertEqual(SessionHistoryStore.visibleLimit, 25)
    }

    func testOldRecentHistoryIsPrunedToTheVisibleTwentyFive() {
        let now = Date(timeIntervalSince1970: 86_400 * 20_000 + 3_600)
        let old = now.addingTimeInterval(-RelayAllowance.windowLength * 2)
        let records = (0..<30).map { offset in
            record(path: .lan, startedAt: old.addingTimeInterval(Double(offset)), duration: 1)
        }

        XCTAssertEqual(SessionHistoryStore.kept(records).count, 25)
    }

    func testSessionsInTheCurrentRelayWindowDoNotRaiseTheCap() {
        let now = Date(timeIntervalSince1970: 86_400 * 20_000 + 3_600)
        let records = (0..<30).map { offset in
            record(path: .relay, startedAt: now.addingTimeInterval(Double(-offset - 10)), duration: 1)
        }

        XCTAssertEqual(SessionHistoryStore.kept(records).count, 25)
        XCTAssertEqual(SessionHistorySummary(records: records).sessionCount, 25)
    }

    func testRecentHistorySummaryAddsConnectedTimeAndVideoBytes() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let summary = SessionHistorySummary(records: [
            record(
                path: .lan,
                startedAt: start,
                duration: 3_600,
                connectedSegments: [DateInterval(start: start, duration: 600)],
                bytes: 1_500
            ),
            record(path: .relay, startedAt: start, duration: 300, bytes: 2_500),
        ])

        XCTAssertEqual(summary.sessionCount, 2)
        XCTAssertEqual(summary.connectedSeconds, 900)
        XCTAssertEqual(summary.videoBytes, 4_000)
    }

    func testRecentHistorySummaryDoesNotSubtractCorruptNegativeBytes() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let summary = SessionHistorySummary(records: [
            record(path: .lan, startedAt: start, duration: 1, bytes: -100),
        ])

        XCTAssertEqual(summary.videoBytes, 0)
    }

    // MARK: - The window

    /// Epoch days, as the relay counts them, so meter and server turn over together.
    func testTheWindowIsEpochDays() {
        let windowNumber = RelayAllowance.windowNumber(at: Date(timeIntervalSince1970: 86_400 * 20_000 + 5))
        XCTAssertEqual(windowNumber, 20_000)

        XCTAssertEqual(
            RelayAllowance.windowStart(windowNumber: 20_000),
            Date(timeIntervalSince1970: 86_400 * 20_000)
        )
    }

    // MARK: - Helpers

    /// A record as filed. connectedSegments is omitted for records not about a gap, giving one stretch over the span.
    private func record(
        id: UUID = UUID(),
        hostID: String? = "A1B2C3",
        path: ClientSessionRecord.Path,
        startedAt: Date,
        duration: TimeInterval,
        connectedSegments: [DateInterval]? = nil,
        bytes: Int64 = 0,
        usedDirectPath: Bool = false,
        endedDeliberately: Bool = false
    ) -> ClientSessionRecord {
        ClientSessionRecord(
            id: id,
            hostID: hostID,
            hostName: "A Mac",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            path: path,
            videoBytesReceived: bytes,
            logs: [],
            usedDirectPath: usedDirectPath,
            connectedSegments: connectedSegments,
            endedDeliberately: endedDeliberately
        )
    }
}
