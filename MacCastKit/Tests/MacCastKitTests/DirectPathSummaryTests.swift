//
//  DirectPathSummaryTests.swift
//  MacCastKitTests
//

import XCTest
@testable import MacCastKit

/// What the finished sessions say about the direct path. The arithmetic is tested here because Xcode 27 cannot run the app target's test action, so a rule left in a view is never checked. See `AGENTS.md`.
/// The real defect is the rate: a session that received no picture must not spread its duration through the average, or failing to deliver reads as a cheaper picture.
final class DirectPathSummaryTests: XCTestCase {

    // MARK: - When there is nothing to say

    func testAnEmptyHistoryHasNothingToSummarise() {
        XCTAssertNil(DirectPathSummary(over: []))
    }

    /// Sessions on this network never went near the relay, so they say nothing about punching and are not counted.
    func testAHistoryThatNeverLeftTheNetworkHasNothingToSummarise() {
        XCTAssertNil(DirectPathSummary(over: [
            record(path: .lan, bytes: 5_000),
            record(path: .lan, bytes: 7_000),
        ]))
    }

    // MARK: - The share

    func testTheShareCountsOnlyTheSessionsThatLeftTheNetwork() {
        let summary = DirectPathSummary(over: [
            record(path: .relay, seconds: 60, bytes: 1_000),
            record(path: .direct, seconds: 60, bytes: 1_000),
            record(path: .direct, seconds: 60, bytes: 1_000),
            record(path: .relay, seconds: 60, bytes: 1_000),
            record(path: .lan, seconds: 60, bytes: 1_000),
            record(path: .lan, seconds: 60, bytes: 1_000),
            record(path: .lan, seconds: 60, bytes: 1_000),
        ])

        XCTAssertEqual(summary?.sessionsOffNetwork, 4)
        XCTAssertEqual(summary?.sessionsDirect, 2)
        XCTAssertEqual(summary?.directShare ?? -1, 0.5, accuracy: 0.0001)
    }

    /// A relay-spliced session still reads `Relay` on its row, but its picture went around the relay, which is what is counted.
    func testASessionThatPunchedCountsAsOneThePictureAvoidedTheRelay() {
        let summary = DirectPathSummary(over: [
            record(path: .relay, seconds: 60, bytes: 1_000, usedDirectPath: true),
        ])

        XCTAssertEqual(summary?.sessionsOffNetwork, 1)
        XCTAssertEqual(summary?.sessionsDirect, 1)
    }

    /// A typed-in address never touches the relay and reports no datagram path, so counting only the flag would misfile it.
    func testASessionOpenedStraightToAnAddressCountsAsOneThatAvoidedTheRelay() {
        let summary = DirectPathSummary(over: [
            record(path: .direct, seconds: 60, bytes: 1_000),
        ])

        XCTAssertEqual(summary?.sessionsDirect, 1)
    }

    /// A record without `usedDirectPath` (an older record) decodes as `false` and cannot be told from a failed punch; the card says so underneath. See `ClientSessionRecordTests`.
    func testARecordWrittenBeforeTheFieldExistedCountsAsRelayed() {
        let summary = DirectPathSummary(over: [
            record(path: .relay, seconds: 60, bytes: 1_000),
        ])

        XCTAssertEqual(summary?.sessionsOffNetwork, 1)
        XCTAssertEqual(summary?.sessionsDirect, 0)
        XCTAssertEqual(summary?.directShare, 0)
    }

    // MARK: - The bytes

    /// Each group's rate is its bytes over its own seconds, so the direct figure is 175, not the 150 of averaging the two sessions' rates.
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

    /// A session that received nothing is no picture, not a cheap one: its minutes must stay out of the denominator (1,000 over 10 seconds, not 1,010).
    func testASessionThatReceivedNoPictureIsLeftOutOfTheRate() {
        let summary = DirectPathSummary(over: [
            record(path: .direct, seconds: 10, bytes: 1_000),
            record(path: .relay, seconds: 1_000, bytes: 0, usedDirectPath: true),
            record(path: .relay, seconds: 30, bytes: 900),
        ])

        XCTAssertEqual(summary?.directBytesPerSecond ?? -1, 100, accuracy: 0.0001)
        XCTAssertEqual(summary?.relayedBytesPerSecond ?? -1, 30, accuracy: 0.0001)
    }

    /// A record can carry bytes and no seconds (`duration` bottoms out at zero); it must not make an infinite rate.
    func testASessionWithNoDurationIsLeftOutOfTheRate() {
        let summary = DirectPathSummary(over: [
            record(path: .direct, seconds: 0, bytes: 5_000),
            record(path: .relay, seconds: 10, bytes: 1_000, usedDirectPath: true),
        ])

        XCTAssertEqual(summary?.directBytesPerSecond ?? -1, 100, accuracy: 0.0001)
    }

    /// A group with no picture has no rate, which the card can decline to draw, not a zero.
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
