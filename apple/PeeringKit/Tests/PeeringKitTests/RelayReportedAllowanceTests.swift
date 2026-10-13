import Foundation
import Testing
@testable import PeeringKit

struct RelayReportedAllowanceTests {
    private static let windowNumber = 20_000.0
    private static let windowStart = RelayAllowance.windowStart(windowNumber: windowNumber)
    private static let freeAllowance: TimeInterval = 1_800

    private func relayRecord(duration: TimeInterval) -> ClientSessionRecord {
        let endedAt = Self.windowStart.addingTimeInterval(7_200)
        return ClientSessionRecord(
            id: UUID(),
            hostID: "A1B2C3",
            hostName: "Studio",
            startedAt: endedAt.addingTimeInterval(-duration),
            endedAt: endedAt,
            path: .relay,
            videoBytesReceived: 0,
            logs: []
        )
    }

    private func state(
        report: RelayRemainingReport?,
        estimate: TimeInterval?,
        now: Date
    ) -> SessionOfferPolicy.State {
        SessionOfferPolicy.State(
            hasOfferedAfterFirstSession: true,
            planIsUnlimited: false,
            hasPaywallOpen: false,
            hasPendingOffer: false,
            relayAllowanceRemainingFraction: estimate.map { $0 / Self.freeAllowance },
            relaySecondsRemainingEstimate: estimate,
            currentWindow: Self.windowNumber,
            offeredWindow: 0,
            relayReport: report,
            relayAllowanceSeconds: Self.freeAllowance,
            now: now
        )
    }

    @Test("the relay's positive number caps the offer at running low even when the local estimate says zero")
    func positiveRelayNumberBeatsZeroEstimate() {
        let received = Self.windowStart.addingTimeInterval(7_200)
        let report = RelayRemainingReport(seconds: 300, receivedAt: received)

        let decision = SessionOfferPolicy.decision(
            after: relayRecord(duration: 60),
            state: state(report: report, estimate: 0, now: received.addingTimeInterval(40))
        )

        #expect(decision?.reason == .runningLow(remaining: 260))
    }

    @Test("a relay that said zero earns the exhausted wording")
    func relayZeroIsExhausted() {
        let received = Self.windowStart.addingTimeInterval(7_200)
        let decision = SessionOfferPolicy.decision(
            after: relayRecord(duration: 60),
            state: state(
                report: RelayRemainingReport(seconds: 0, receivedAt: received),
                estimate: 900,
                now: received
            )
        )

        #expect(decision?.reason == .quotaExhausted)
    }

    @Test("a relay with plenty left makes no offer even when the local estimate says nearly spent")
    func plentyLeftBeatsLowEstimate() {
        let received = Self.windowStart.addingTimeInterval(7_200)
        let decision = SessionOfferPolicy.decision(
            after: relayRecord(duration: 60),
            state: state(
                report: RelayRemainingReport(seconds: 1_703, receivedAt: received),
                estimate: 0,
                now: received
            )
        )

        #expect(decision == nil)
    }

    @Test("a positive report that has run down to zero is still running low, not exhausted")
    func decayedPositiveReportStaysRunningLow() {
        let received = Self.windowStart.addingTimeInterval(7_200)
        let decision = SessionOfferPolicy.decision(
            after: relayRecord(duration: 60),
            state: state(
                report: RelayRemainingReport(seconds: 100, receivedAt: received),
                estimate: 0,
                now: received.addingTimeInterval(500)
            )
        )

        #expect(decision?.reason == .runningLow(remaining: 0))
    }

    @Test("without a relay number the local estimate decides, as an older relay needs")
    func absentReportFallsBackToEstimate() {
        let now = Self.windowStart.addingTimeInterval(7_200)
        let decision = SessionOfferPolicy.decision(
            after: relayRecord(duration: 60),
            state: state(report: nil, estimate: 0, now: now)
        )

        #expect(decision?.reason == .quotaExhausted)
    }

    @Test("a number from yesterday's window is ignored and the estimate decides")
    func reportFromEarlierWindowIsIgnored() {
        let received = Self.windowStart.addingTimeInterval(-60)
        let now = Self.windowStart.addingTimeInterval(7_200)
        let report = RelayRemainingReport(seconds: 1_703, receivedAt: received)

        #expect(report.remaining(at: now) == nil)
        let decision = SessionOfferPolicy.decision(
            after: relayRecord(duration: 60),
            state: state(report: report, estimate: 120, now: now)
        )
        #expect(decision?.reason == .runningLow(remaining: 120))
    }

    @Test("the paywall reason helper never says exhausted against a positive relay number")
    func lowAllowanceReasonRespectsTheRelay() {
        let received = Self.windowStart.addingTimeInterval(7_200)
        let report = RelayRemainingReport(seconds: 50, receivedAt: received)

        #expect(SessionOfferPolicy.lowAllowanceReason(estimate: 0, report: report, now: received) == .runningLow(remaining: 50))
        #expect(SessionOfferPolicy.lowAllowanceReason(estimate: 0, report: nil, now: received) == .quotaExhausted)
    }

    @Test("a drop, a long gap and a resume count only the stretches the session was connected")
    func resumedSessionDoesNotCountTheGap() {
        let firstConnect = Self.windowStart.addingTimeInterval(3_600)
        let dropped = firstConnect.addingTimeInterval(100)
        let filedOnDrop = SessionContinuation(id: UUID(), startedAt: firstConnect).filed(
            endedAt: dropped,
            segmentStartedAt: firstConnect,
            path: .relay,
            hostID: "A1B2C3",
            hostName: "Studio",
            segmentBytes: 0,
            logs: [],
            usedDirectPath: false,
            endedDeliberately: false
        )
        let resumedAt = firstConnect.addingTimeInterval(6_300)
        let live = DateInterval(start: resumedAt, duration: 30)

        let used = RelayAllowance.secondsUsed(
            records: [filedOnDrop],
            windowStart: Self.windowStart,
            liveRelaySegments: [live]
        )
        #expect(used == 130)

        let resumedRecord = SessionContinuation.continued(in: [filedOnDrop], hostID: "A1B2C3", path: .relay)?.filed(
            endedAt: resumedAt.addingTimeInterval(30),
            segmentStartedAt: resumedAt,
            path: .relay,
            hostID: "A1B2C3",
            hostName: "Studio",
            segmentBytes: 0,
            logs: [],
            usedDirectPath: false,
            endedDeliberately: true
        )
        #expect(resumedRecord?.duration == 6_330)
        let usedAfter = RelayAllowance.secondsUsed(
            records: resumedRecord.map { [$0] } ?? [],
            windowStart: Self.windowStart,
            liveRelaySegments: []
        )
        #expect(usedAfter == 130)
    }
}
