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
///
/// **And the third rule here, added with the record's connected time.** A session the app puts
/// back after a drop is one row rather than two, which is a decision about the history and a sum
/// about the allowance at once: the record a drop filed is continued, so the same Mac cannot be
/// counted twice, and only its connected seconds are ever spent. See ``SessionContinuation``.
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

    /// **The gap is not charged for.** A session the app put back is one record covering the
    /// minutes the phone spent backgrounded, the ladder spent retrying and the Mac spent
    /// unreachable, and the relay splices none of them. The meter is the allowance, so a record
    /// summed by its span would cut a free user off early, on the screen they go to in order to
    /// find out why.
    func testRelayTimeCountsConnectedSecondsAndNotTheGap() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let used = RelayAllowance.secondsUsed(
            records: [
                // Two hours of span, ten minutes of which the session was up.
                record(path: .relay, startedAt: start, duration: 7_200, connectedSeconds: 600)
            ],
            windowStart: start,
            liveRelaySeconds: []
        )
        XCTAssertEqual(used, 600)
    }

    /// The same sum over a live session, where the seconds are this segment's: the half of a
    /// continued session that has already happened is in the history, still, as the record the
    /// live one continues, and counting it in both places would spend the allowance twice.
    func testALiveSessionAddsOnlyTheSegmentItIsRunning() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let used = RelayAllowance.secondsUsed(
            records: [record(path: .relay, startedAt: start, duration: 3_600, connectedSeconds: 300)],
            windowStart: start,
            liveRelaySeconds: [120]
        )
        XCTAssertEqual(used, 420)
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

    // MARK: - Continuing a session across a drop

    /// The row the user already had, continued rather than a second one started beside it.
    func testAResumeContinuesTheRecordTheDropFiled() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let dropped = record(
            path: .relay, startedAt: start, duration: 300, connectedSeconds: 300, bytes: 4_096
        )

        let continuation = SessionContinuation.continued(
            in: [dropped], hostID: "A1B2C3", path: .relay
        )

        XCTAssertEqual(continuation?.id, dropped.id)
        XCTAssertEqual(continuation?.startedAt, dropped.startedAt)
        XCTAssertEqual(continuation?.connectedSeconds, 300)
        XCTAssertEqual(continuation?.videoBytesReceived, 4_096)
    }

    /// **The arithmetic the whole thing is for.** The record filed when the session finally ends
    /// keeps the identity and the start of the one the drop filed, carries the bytes of both
    /// segments, counts the connected time of both, and spans from the first connect to the last
    /// disconnect with the gap in it.
    func testTheRecordFiledForAResumedSessionKeepsItsIdentityAndItsBytesAccumulate() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let dropped = record(path: .relay, startedAt: start, duration: 300, bytes: 4_096)
        let continuation = SessionContinuation.continued(
            in: [dropped], hostID: "A1B2C3", path: .relay
        )

        // Three hours later the phone comes back, is up for ten minutes, and disconnects.
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
    }

    /// A session that never dropped is a continuation of nothing, and the record it files has to
    /// come out exactly as it always did: connected from end to end, with its own bytes.
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

    /// A session the user ended is finished with, so the next connection they make to that Mac is
    /// a row of its own. Without this, Disconnect followed by Connect an hour later would fold two
    /// sessions into one.
    func testARecordTheUserEndedIsNotContinued() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let ended = record(path: .relay, startedAt: start, duration: 300, endedDeliberately: true)

        XCTAssertNil(SessionContinuation.continued(in: [ended], hostID: "A1B2C3", path: .relay))
    }

    /// **The newest record for the Mac, and no other.** A deliberate end writes a record too, so a
    /// rule that reached past one would continue a session that came and went before it rather than
    /// the one this reconnect is answering.
    func testADeliberateEndStopsTheSearchRatherThanBeingLookedPast() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let dropped = record(path: .relay, startedAt: start, duration: 600)
        let ended = record(
            path: .relay, startedAt: start.addingTimeInterval(3_600), duration: 60,
            endedDeliberately: true
        )

        // Newest first, which is how the store keeps them.
        XCTAssertNil(
            SessionContinuation.continued(in: [ended, dropped], hostID: "A1B2C3", path: .relay)
        )
    }

    func testARecordForAnotherMacIsNotContinued() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let other = record(hostID: "D4E5F6", path: .relay, startedAt: start, duration: 300)

        XCTAssertNil(SessionContinuation.continued(in: [other], hostID: "A1B2C3", path: .relay))
    }

    /// A Mac that never said which one it is has nothing of its own to continue: `nil == nil` would
    /// otherwise match every record the app has been unable to attribute.
    func testARecordWithNoMacIsNotContinuedByASessionWithNoMac() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let unattributed = record(hostID: nil, path: .relay, startedAt: start, duration: 300)

        XCTAssertNil(SessionContinuation.continued(in: [unattributed], hostID: nil, path: .relay))
    }

    /// **Money.** A record is metered by its path and its connected time together, so one carrying
    /// minutes from two paths under a single path would either charge the relay for a splice that
    /// did not happen or lose one that did.
    func testARecordIsNotContinuedOnADifferentPath() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let onTheRelay = record(path: .relay, startedAt: start, duration: 300)

        XCTAssertNil(SessionContinuation.continued(in: [onTheRelay], hostID: "A1B2C3", path: .lan))
        XCTAssertNil(SessionContinuation.continued(in: [onTheRelay], hostID: "A1B2C3", path: .direct))
    }

    /// The punching flag is the session's answer rather than this segment's: it is filed to say how
    /// often punching works, and a session that punched before the drop is one it worked in.
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

    /// A record as it was filed, with the ordinary answer for everything the test is not about.
    ///
    /// `connectedSeconds` is left out for the records that are not about a gap: the answer is then
    /// the span, which is only ever true of a session that was never dropped.
    private func record(
        id: UUID = UUID(),
        hostID: String? = "A1B2C3",
        path: ClientSessionRecord.Path,
        startedAt: Date,
        duration: TimeInterval,
        connectedSeconds: TimeInterval? = nil,
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
            connectedSeconds: connectedSeconds ?? duration,
            endedDeliberately: endedDeliberately
        )
    }
}
