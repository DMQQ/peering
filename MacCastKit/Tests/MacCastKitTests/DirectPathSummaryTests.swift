//
//  DirectPathSummaryTests.swift
//  MacCastKitTests
//

import XCTest
@testable import MacCastKit

/// What the finished sessions say about the direct path, and what they must not be made to say.
///
/// **Why the arithmetic is here rather than on the screen.** Every figure the Sessions tab draws
/// is a division, and a division has a denominator that can be zero, a numerator that can be
/// counted twice, and a group whose sessions carried no picture at all. On the screen none of
/// those is runnable, and Xcode 27 cannot run the app target's test action at all, so a rule left
/// in a view is a rule nobody checks. See `AGENTS.md`.
///
/// The one case with a real defect behind it is the rate: a session that received no picture is a
/// session whose picture cost nothing to nobody, and spreading its duration through the average
/// reports the picture as cheaper the more often it failed to arrive.
final class DirectPathSummaryTests: XCTestCase {

    // MARK: - When there is nothing to say

    /// A history with nothing in it has no share to draw, and drawing one would be the absence of
    /// an answer wearing the clothes of an answer.
    func testAnEmptyHistoryHasNothingToSummarise() {
        XCTAssertNil(DirectPathSummary(over: []))
    }

    /// **Sessions on this network are not sessions that avoided the relay.** They never went near
    /// it, so a history of only these has nothing to report about punching, and counting them
    /// would read as a feature working perfectly on a phone that had never left the house.
    func testAHistoryThatNeverLeftTheNetworkHasNothingToSummarise() {
        XCTAssertNil(DirectPathSummary(over: [
            record(path: .lan, bytes: 5_000),
            record(path: .lan, bytes: 7_000),
        ]))
    }

    // MARK: - The share

    /// The denominator is the sessions that had to leave, and the numerator is the ones whose
    /// picture avoided the relay.
    func testTheShareCountsOnlyTheSessionsThatLeftTheNetwork() {
        let summary = DirectPathSummary(over: [
            record(path: .relay, seconds: 60, bytes: 1_000),
            record(path: .direct, seconds: 60, bytes: 1_000),
            record(path: .direct, seconds: 60, bytes: 1_000),
            record(path: .relay, seconds: 60, bytes: 1_000),
            // Three sessions that never had a relay to avoid, and are not part of the question.
            record(path: .lan, seconds: 60, bytes: 1_000),
            record(path: .lan, seconds: 60, bytes: 1_000),
            record(path: .lan, seconds: 60, bytes: 1_000),
        ])

        XCTAssertEqual(summary?.sessionsOffNetwork, 4)
        XCTAssertEqual(summary?.sessionsDirect, 2)
        XCTAssertEqual(summary?.directShare ?? -1, 0.5, accuracy: 0.0001)
    }

    /// **The case the Sessions list cannot show.** A session the relay spliced still reads as
    /// `Relay` on its row, because that is the connection's path and the relay bills for it. Its
    /// picture went around the relay all the same, and that is the fact being counted.
    func testASessionThatPunchedCountsAsOneThePictureAvoidedTheRelay() {
        let summary = DirectPathSummary(over: [
            record(path: .relay, seconds: 60, bytes: 1_000, usedDirectPath: true),
        ])

        XCTAssertEqual(summary?.sessionsOffNetwork, 1)
        XCTAssertEqual(summary?.sessionsDirect, 1)
    }

    /// A typed-in address never touches the relay at all, and those sessions report no datagram
    /// path, because there is no relay lane to report one on. Counting only the flag would file
    /// every one of them as a session the picture went through the relay for.
    func testASessionOpenedStraightToAnAddressCountsAsOneThatAvoidedTheRelay() {
        let summary = DirectPathSummary(over: [
            record(path: .direct, seconds: 60, bytes: 1_000),
        ])

        XCTAssertEqual(summary?.sessionsDirect, 1)
    }

    /// **A record that did not punch counts as one that did not.** This is what an older record
    /// is: `usedDirectPath` was a field the type grew after records already existed, and a record
    /// written without the key decodes as `false` — see `ClientSessionRecordTests`, which holds
    /// the decode itself. There is no way to tell such a record from one whose punch failed, so
    /// the honest answer is the one the app gave at the time, and the card says so underneath.
    func testARecordWrittenBeforeTheFieldExistedCountsAsRelayed() {
        let summary = DirectPathSummary(over: [
            record(path: .relay, seconds: 60, bytes: 1_000),
        ])

        XCTAssertEqual(summary?.sessionsOffNetwork, 1)
        XCTAssertEqual(summary?.sessionsDirect, 0)
        XCTAssertEqual(summary?.directShare, 0)
    }

    // MARK: - The bytes

    /// The two figures are each group's picture bytes over its own seconds, which is the only
    /// comparison the two groups support: their totals differ mostly by how many sessions there
    /// were, and the sessions are not the same length either.
    ///
    /// **The direct figure is 175 and not the 150 that averaging the two sessions' own rates would
    /// give.** A group's rate is its bytes over its seconds, so the long session weighs more than
    /// the short one, which is what "the picture cost this much while it was arriving" means.
    func testTheRatesAreEachGroupsPicturePerSecond() {
        let summary = DirectPathSummary(over: [
            // Direct: 1,000 bytes over 10 seconds, then 6,000 over 30: 7,000 over 40.
            record(path: .direct, seconds: 10, bytes: 1_000),
            record(path: .relay, seconds: 30, bytes: 6_000, usedDirectPath: true),
            // Relayed: 900 bytes over 30 seconds.
            record(path: .relay, seconds: 30, bytes: 900),
        ])

        XCTAssertEqual(summary?.directBytesPerSecond ?? -1, 175, accuracy: 0.0001)
        XCTAssertEqual(summary?.relayedBytesPerSecond ?? -1, 30, accuracy: 0.0001)
    }

    /// **The trap.** A session that received nothing is not a cheap picture, it is no picture, and
    /// leaving its minutes in the denominator drags the group's rate towards zero by exactly how
    /// long it failed for. The direct rate here is 1,000 over 10 seconds and not 1,000 over 1,010.
    func testASessionThatReceivedNoPictureIsLeftOutOfTheRate() {
        let summary = DirectPathSummary(over: [
            record(path: .direct, seconds: 10, bytes: 1_000),
            record(path: .relay, seconds: 1_000, bytes: 0, usedDirectPath: true),
            record(path: .relay, seconds: 30, bytes: 900),
        ])

        XCTAssertEqual(summary?.directBytesPerSecond ?? -1, 100, accuracy: 0.0001)
        XCTAssertEqual(summary?.relayedBytesPerSecond ?? -1, 30, accuracy: 0.0001)
    }

    /// A record can carry bytes and no seconds — `duration` bottoms out at zero rather than
    /// running backwards, so an instant session is a real record. It has no rate to contribute and
    /// must not make one infinite.
    func testASessionWithNoDurationIsLeftOutOfTheRate() {
        let summary = DirectPathSummary(over: [
            record(path: .direct, seconds: 0, bytes: 5_000),
            record(path: .relay, seconds: 10, bytes: 1_000, usedDirectPath: true),
        ])

        XCTAssertEqual(summary?.directBytesPerSecond ?? -1, 100, accuracy: 0.0001)
    }

    /// Nothing in a group carried a picture, so that group has no rate — which is an answer the
    /// card can decline to draw, and not a zero it would have to be honest about inventing.
    func testAGroupThatCarriedNoPictureHasNoRate() {
        let summary = DirectPathSummary(over: [
            record(path: .direct, seconds: 600, bytes: 0),
            record(path: .relay, seconds: 30, bytes: 900),
        ])

        XCTAssertNil(summary?.directBytesPerSecond)
        XCTAssertEqual(summary?.relayedBytesPerSecond ?? -1, 30, accuracy: 0.0001)
    }

    // MARK: - Helpers

    private func record(
        path: ClientSessionRecord.Path,
        seconds: TimeInterval = 60,
        bytes: Int64 = 0,
        usedDirectPath: Bool = false
    ) -> ClientSessionRecord {
        let start = Date(timeIntervalSince1970: 1_000_000)
        return ClientSessionRecord(
            id: UUID(),
            hostID: "A1B2C3",
            hostName: "A Mac",
            startedAt: start,
            endedAt: start.addingTimeInterval(seconds),
            path: path,
            videoBytesReceived: bytes,
            logs: [],
            usedDirectPath: usedDirectPath
        )
    }
}
