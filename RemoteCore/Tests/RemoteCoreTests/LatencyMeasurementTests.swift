import Foundation
import Testing

@testable import RemoteCore

/// Which ping a pong answers.
///
/// Everything here is about *timing*, and a test cannot wait for timing. So the clock is a number
/// the test supplies, and each case is a shape the network produces in practice: a reply that
/// crossed the next ping, a reply to a question that was given up on, a Mac that echoes nothing.
@Suite("The pings in flight")
struct PingLedgerTests {
    /// The bug, stated as the bad reading it produced.
    ///
    /// Ping one goes out, ping two follows a second later, and the reply to ping one arrives after
    /// it. The old code had one timestamp, already overwritten by ping two, so it measured this
    /// reply against a ping sent a moment ago: 500 ms where the truth is 1500. Wrong in the
    /// reassuring direction, at exactly the moment the number was worth reading.
    @Test func aLatePongIsMeasuredAgainstThePingItAnswers() {
        var ledger = PingLedger()
        let first = ledger.record(now: 0)
        _ = ledger.record(now: 1_000_000_000)

        let answered = ledger.answered(sequence: first.sequence)

        #expect(answered?.sequence == first.sequence)
        #expect(answered?.sentAtNanoseconds == 0)
    }

    /// A reply that answers nothing cannot be timed, and guessing at it is how the number started
    /// lying. It is dropped.
    @Test func aPongForAPingThatIsNoLongerInFlightAnswersNothing() {
        var ledger = PingLedger()
        let first = ledger.record(now: 0)
        _ = ledger.answered(sequence: first.sequence)

        #expect(ledger.answered(sequence: first.sequence) == nil)
    }

    /// The other half of the same bug: a lost ping must never become a very fast one.
    ///
    /// Three went out, the third came back, and the first two were never answered. If they stayed
    /// in the list they would be handed to some later reply and reported as round trips of several
    /// seconds, or worse, credited to a reply that had already been counted.
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

    /// A Mac that predates the number echoes nothing, and it still answered *something*.
    ///
    /// The oldest question open is the only reading that cannot be wrong in the reassuring
    /// direction, which is the direction a single timestamp was wrong in.
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

    /// A link that has stopped answering must not grow the list for the rest of the session.
    @Test func theListOfPingsInFlightIsBounded() {
        var ledger = PingLedger()
        for tick in 0..<20 {
            _ = ledger.record(now: UInt64(tick) * 1_000_000_000)
        }

        #expect(ledger.inFlight.count == PingLedger.inFlightLimit)
    }

    /// Numbers keep going up across the whole session, so a reply to a ping from before the list
    /// was trimmed cannot be mistaken for a reply to a later one.
    @Test func everyPingGetsItsOwnNumber() {
        var ledger = PingLedger()
        let numbers = (0..<6).map { ledger.record(now: UInt64($0)).sequence }

        #expect(Set(numbers).count == numbers.count)
        #expect(numbers == numbers.sorted())
    }
}

/// The window the reported figure is drawn from.
@Suite("The latency window")
struct LatencyWindowTests {
    @Test func theFigureIsTheMiddleOfWhatIsInTheWindow() {
        var window = LatencyWindow(length: 10)
        for (tick, milliseconds) in [40.0, 300, 42, 44, 46].enumerated() {
            window.add(milliseconds, at: Double(tick))
        }

        #expect(window.reported == 44)
    }

    /// The window is a duration, so a sample leaves it because of when it arrived rather than
    /// because enough other samples arrived after it.
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

    /// A median rather than a mean, which is the whole reason one stall does not move the figure.
    @Test func oneStallDoesNotOwnTheFigure() {
        var window = LatencyWindow(length: 10)
        for (tick, milliseconds) in [40.0, 41, 900, 42, 43].enumerated() {
            window.add(milliseconds, at: Double(tick))
        }

        #expect(window.reported == 42)
    }

    /// The figure does not move until the samples under it do, which is what stops it re-centring
    /// on every single reading.
    @Test func oneNewSampleDoesNotReCentreTheFigure() {
        var window = LatencyWindow(length: 10)
        for (tick, milliseconds) in [40.0, 41, 42, 43, 44].enumerated() {
            window.add(milliseconds, at: Double(tick))
        }
        let before = window.reported

        window.add(400, at: 5)

        #expect(before == 42)
        // Six samples now, so the figure is the mean of the two middle ones. A tenth of a
        // millisecond of movement for a round trip ten times the others, which is the point.
        #expect(window.reported == 42.5)
    }
}

/// A lane ping as it actually travels: sealed by one end, opened by the other.
///
/// The number is the whole point of the change, so it is worth checking that it survives the
/// sealing rather than only that the ledger can match one it was handed directly.
@Suite("A ping on the datagram lane")
struct LanePingWireTests {
    private let token = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })

    private func schedule() -> VideoKeySchedule {
        VideoKeySchedule(secret: Data(repeating: 9, count: VideoKeySchedule.secretSize))
    }

    /// What the relay does between the two ends, which is the one part of the contract written in
    /// another repository.
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

    /// The Mac's half of it: the payload it does not read is the payload it hands back, and the
    /// number has to come out the other end unchanged for the client to be able to time anything.
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

    /// A ping and a pong share the lane with the picture, and the opener that puts pictures back
    /// together must not read either as one. This is the assertion behind the guard in
    /// `handleDatagram`: a pong that reached the renderer would be a frame with no video in it.
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
