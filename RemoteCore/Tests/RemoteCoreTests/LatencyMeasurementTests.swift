import Foundation
import Testing

@testable import RemoteCore

@Suite("The pings in flight")
struct PingLedgerTests {
    @Test func aLatePongIsMeasuredAgainstThePingItAnswers() {
        var ledger = PingLedger()
        let first = ledger.record(now: 0)
        _ = ledger.record(now: 1_000_000_000)

        let answered = ledger.answered(sequence: first.sequence)

        #expect(answered?.sequence == first.sequence)
        #expect(answered?.sentAtNanoseconds == 0)
    }

    @Test func aPongForAPingThatIsNoLongerInFlightAnswersNothing() {
        var ledger = PingLedger()
        let first = ledger.record(now: 0)
        _ = ledger.answered(sequence: first.sequence)

        #expect(ledger.answered(sequence: first.sequence) == nil)
    }

    @Test func pingsOlderThanTheOneAnsweredAreDiscarded() {
        var ledger = PingLedger()
        let first = ledger.record(now: 0)
        let second = ledger.record(now: 1_000_000_000)
        let third = ledger.record(now: 2_000_000_000)

        #expect(ledger.answered(sequence: third.sequence)?.sequence == third.sequence)
        #expect(ledger.inFlight.isEmpty)
        #expect(ledger.answered(sequence: first.sequence) == nil)
        #expect(ledger.answered(sequence: second.sequence) == nil)
    }

    @Test func anEmptyPongAnswersTheOldestQuestionStillOpen() {
        var ledger = PingLedger()
        let first = ledger.record(now: 0)
        _ = ledger.record(now: 1_000_000_000)

        #expect(ledger.answered(sequence: nil)?.sequence == first.sequence)
    }

    @Test func aPongWithNothingOutstandingAnswersNothing() {
        var ledger = PingLedger()

        #expect(ledger.answered(sequence: nil) == nil)
        #expect(ledger.answered(sequence: 1) == nil)
    }

    @Test func theListOfPingsInFlightIsBounded() {
        var ledger = PingLedger()
        for tick in 0..<20 {
            _ = ledger.record(now: UInt64(tick) * 1_000_000_000)
        }

        #expect(ledger.inFlight.count == PingLedger.inFlightLimit)
    }

    @Test func everyPingGetsItsOwnNumber() {
        var ledger = PingLedger()
        let numbers = (0..<6).map { ledger.record(now: UInt64($0)).sequence }

        #expect(Set(numbers).count == numbers.count)
        #expect(numbers == numbers.sorted())
    }
}

@Suite("The latency window")
struct LatencyWindowTests {
    @Test func theFigureIsTheMiddleOfWhatIsInTheWindow() {
        var window = LatencyWindow(length: 10)
        for (tick, milliseconds) in [40.0, 300, 42, 44, 46].enumerated() {
            window.add(milliseconds, at: Double(tick))
        }

        #expect(window.reported == 44)
    }

    @Test func aSampleLeavesTheWindowOnceItIsOldEnough() {
        var window = LatencyWindow(length: 10)
        window.add(30, at: 0)
        window.add(200, at: 11)

        #expect(window.samples.count == 1)
        #expect(window.reported == 200)
    }

    @Test func aWindowWithNothingInItReportsNothing() {
        let window = LatencyWindow(length: 10)

        #expect(window.reported == nil)
    }

    @Test func oneStallDoesNotOwnTheFigure() {
        var window = LatencyWindow(length: 10)
        for (tick, milliseconds) in [40.0, 41, 900, 42, 43].enumerated() {
            window.add(milliseconds, at: Double(tick))
        }

        #expect(window.reported == 42)
    }

    @Test func oneNewSampleDoesNotReCentreTheFigure() {
        var window = LatencyWindow(length: 10)
        for (tick, milliseconds) in [40.0, 41, 42, 43, 44].enumerated() {
            window.add(milliseconds, at: Double(tick))
        }
        let before = window.reported

        window.add(400, at: 5)

        #expect(before == 42)
        #expect(window.reported == 42.5)
    }
}

@Suite("A ping on the datagram lane")
struct LanePingWireTests {
    private let token = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })

    private func schedule() -> VideoKeySchedule {
        VideoKeySchedule(secret: Data(repeating: 9, count: VideoKeySchedule.secretSize))
    }

    /// The relay's behaviour, the one contract written in another repository.
    private func forwarded(_ datagrams: [Data]) -> [Data] {
        datagrams.map { Data($0.dropFirst(VideoDatagram.tokenSize)) }
    }

    @Test func aSealedPingOpensAsAPingCarryingItsNumber() throws {
        var sealer = try schedule().sealer(token: token, direction: .clientToHost)
        var opener = schedule().opener(direction: .clientToHost)

        let datagrams = sealer.seal(
            kind: .ping, payload: try MessageCodec.encode(PingPayload(sequence: 42))
        )
        #expect(datagrams.count == 1)

        var opened: Frame?
        for datagram in forwarded(datagrams) { opened = try opener.open(datagram) }

        let frame = try #require(opened)
        #expect(frame.kind == .ping)
        let decoded = try MessageCodec.decode(PingPayload.self, from: frame.payload)
        #expect(decoded.sequence == 42)
    }

    @Test func theEchoedPongCarriesTheSameNumberBack() throws {
        let schedule = schedule()
        var toHost = try schedule.sealer(token: token, direction: .clientToHost)
        var atHost = schedule.opener(direction: .clientToHost)
        var fromHost = try schedule.sealer(token: token, direction: .hostToClient)
        var atClient = schedule.opener(direction: .hostToClient)

        var ping: Frame?
        for datagram in forwarded(toHost.seal(
            kind: .ping, payload: try MessageCodec.encode(PingPayload(sequence: 7))
        )) { ping = try atHost.open(datagram) }

        let question = try #require(ping)
        #expect(question.kind == .ping)

        var pong: Frame?
        for datagram in forwarded(fromHost.seal(kind: .pong, payload: question.payload)) {
            pong = try atClient.open(datagram)
        }

        let reply = try #require(pong)
        #expect(reply.kind == .pong)
        let decoded = try MessageCodec.decode(PingPayload.self, from: reply.payload)
        #expect(decoded.sequence == 7)
    }

    /// Pings and pongs share the lane with the picture and must not be read as pieces of one: a pong reaching the renderer would be a frame with no video.
    @Test func aPongIsNotAPieceOfAPicture() throws {
        var sealer = try schedule().sealer(token: token, direction: .hostToClient)
        var opener = schedule().opener(direction: .hostToClient)

        var opened: Frame?
        for datagram in forwarded(sealer.seal(
            kind: .pong, payload: try MessageCodec.encode(PingPayload(sequence: 1))
        )) { opened = try opener.open(datagram) }

        let frame = try #require(opened)
        #expect(frame.kind != .videoFrame)
        #expect(frame.kind != .videoChunk)
    }
}

/// Phone changes network: the path under the control connection goes away and nothing reports it.
@Suite("Control-channel silence")
struct ControlSilenceTests {
    private let silence = ControlSilence(limit: 10)

    /// A watchdog that ticked half a second ago, which is how it normally runs.
    private func verdict(
        isReady: Bool = true,
        readyAt: TimeInterval? = 0,
        lastReplyAt: TimeInterval? = nil,
        restartedAt: TimeInterval? = nil,
        previousCheckAt: TimeInterval? = 99.5,
        now: TimeInterval = 100
    ) -> ControlSilence.Verdict {
        silence.judge(
            isReady: isReady, readyAt: readyAt, lastReplyAt: lastReplyAt,
            restartedAt: restartedAt, previousCheckAt: previousCheckAt, now: now
        )
    }

    @Test func aChannelThatHasAnsweredRecentlyIsHealthy() {
        #expect(verdict(lastReplyAt: 97) == .healthy)
    }

    @Test func aChannelSilentPastTheLimitHasExpired() {
        #expect(verdict(lastReplyAt: 89) == .expired)
    }

    /// Without a baseline from the ready moment it could never expire.
    @Test func beforeTheFirstReplyTheClockRunsFromWhenTheSessionBecameReady() {
        #expect(verdict(readyAt: 95) == .healthy)
        #expect(verdict(readyAt: 80) == .expired)
    }

    @Test func aSessionThatIsNotReadyNeverExpires() {
        #expect(verdict(isReady: false, readyAt: 0, lastReplyAt: 0) == .healthy)
    }

    @Test func withNoBaselineThereIsNoOpinion() {
        #expect(verdict(readyAt: nil, lastReplyAt: nil) == .healthy)
    }

    @Test func theLimitItselfIsNotYetExpired() {
        #expect(verdict(lastReplyAt: 90) == .healthy)
    }

    /// The backgrounded app: nothing ran for twenty seconds, so no ping went out and no pong was read.
    @Test func aWatchdogThatWasFrozenDoesNotBlameTheNetwork() {
        #expect(verdict(lastReplyAt: 70, previousCheckAt: 75) == .resumedFromFreeze)
    }

    @Test func aFreezeThatLeftTheChannelRecentlyAnsweredIsNotAnIssue() {
        #expect(verdict(lastReplyAt: 98, previousCheckAt: 75) == .healthy)
    }

    @Test func afterAFreezeTheClockRunsFromWhenItEnded() {
        #expect(verdict(lastReplyAt: 70, restartedAt: 95) == .healthy)
        #expect(verdict(lastReplyAt: 70, restartedAt: 85) == .expired)
    }

    @Test func aFirstCheckHasNoPreviousTickToCompareWith() {
        #expect(verdict(lastReplyAt: 70, previousCheckAt: nil) == .expired)
    }

    @Test func aGapJustUnderTheFreezeThresholdStillCountsAsSilence() {
        #expect(verdict(lastReplyAt: 70, previousCheckAt: 97.5) == .expired)
    }
}

@Suite("Waiting for an answer")
struct AnswerGraceTests {
    @Test func aMacOnTheSameWiFiGetsTheFloor() {
        #expect(ClientSession.answerGrace(roundTripMilliseconds: 8) == 0.4)
    }

    @Test func aRelayFromAbroadGetsFourRoundTrips() {
        #expect(abs(ClientSession.answerGrace(roundTripMilliseconds: 250) - 1.2) < 0.0001)
    }

    @Test func aTerribleLinkIsCappedAtTheOldFigure() {
        #expect(ClientSession.answerGrace(roundTripMilliseconds: 2000) == 1.5)
    }

    @Test func noMeasurementYetIsTreatedAsSlow() {
        #expect(ClientSession.answerGrace(roundTripMilliseconds: nil) == 1.0)
    }
}
