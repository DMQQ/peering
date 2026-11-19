import Foundation
import Testing
@testable import RemoteCore

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Two ends joined by a carrier that can drop, duplicate and reorder what it is given, one step per 50 ms.
private struct Pair {
    var a = StreamMux()
    var b = StreamMux()
    var atB: [Frame] = []
    var atA: [Frame] = []
    var clock = ContinuousClock.now
    var random = SplitMix(state: 11)
    var lossPercent = 0
    var carrier: StreamMux.Carrier = .lossy
    /// Payloads from A the carrier is told to lose, by stream and offset, once.
    var dropFromA: (Data) -> Bool = { _ in false }

    private mutating func carry(_ payloads: [Data], fromA: Bool) throws {
        var wire = payloads
        if carrier == .lossy {
            wire = wire.filter { payload in
                if fromA, dropFromA(payload) { return false }
                return Int.random(in: 0..<100, using: &random) >= lossPercent
            }
            wire.shuffle(using: &random)
        }
        for payload in wire {
            if fromA { atB += try b.receive(payload, now: clock) } else { atA += try a.receive(payload, now: clock) }
        }
    }

    mutating func step() throws {
        clock += .milliseconds(50)
        try carry(a.outgoing(now: clock, carrier: carrier), fromA: true)
        try carry(b.outgoing(now: clock, carrier: carrier), fromA: false)
    }

    mutating func run(until done: (Pair) -> Bool, limit: Int = 4000) throws {
        var steps = 0
        while !done(self), steps < limit { try step(); steps += 1 }
    }
}

struct StreamMuxTests {
    private func command(_ number: Int) -> Frame { Frame(kind: .command, payload: Data("command \(number)".utf8)) }
    private func fileChunk(_ number: Int) -> Frame {
        Frame(kind: .terminalEvent, payload: Data(#"{"fileRange":{"n":\#(number)}}"#.utf8) + Data(count: 3000))
    }

    @Test func aStreamFrameSurvivesEncodingAndRejectsGarbage() {
        let frame = StreamFrame(stream: .files, pipe: .data(offset: 9, payload: Data([1, 2, 3])))
        #expect(StreamFrame.decode(frame.encoded()) == frame)
        #expect(StreamFrame.decode(StreamFrame(stream: .pulse, pipe: .ack(upTo: 5)).encoded())?.stream == .pulse)
        #expect(StreamFrame.decode(Data()) == nil)
        #expect(StreamFrame.decode(Data([99, 0, 0, 0, 0, 0, 0, 0, 0, 0])) == nil)
    }

    @Test func framesOfEveryStreamArriveInOrderOverALossyReorderingCarrier() throws {
        var pair = Pair()
        pair.lossPercent = 30
        for number in 0..<30 {
            pair.a.enqueue(command(number))
            pair.a.enqueue(fileChunk(number))
        }
        try pair.run { $0.atB.count == 60 }
        #expect(pair.atB.filter { $0.kind == .command } == (0..<30).map(command))
        #expect(pair.atB.filter { $0.kind == .terminalEvent } == (0..<30).map(fileChunk))
    }

    @Test func aLossInTheFilesStreamDoesNotDelayACommand() throws {
        var pair = Pair()
        pair.dropFromA = { payload in
            guard let frame = StreamFrame.decode(payload), frame.stream == .files,
                  case .data(let offset, _) = frame.pipe else { return false }
            return offset == 0
        }
        pair.a.enqueue(fileChunk(0))
        pair.a.enqueue(command(1))
        try pair.step()
        // The first segment of the transfer is gone, and the command it was sent beside has arrived.
        #expect(pair.atB.contains(command(1)))
        #expect(!pair.atB.contains { $0.kind == .terminalEvent })
    }

    @Test func aCommandSentBehindALargeTransferGoesFirst() {
        var mux = StreamMux()
        for number in 0..<40 { mux.enqueue(fileChunk(number)) }
        mux.enqueue(command(1))
        let payloads = mux.outgoing(now: .now, carrier: .lossy)
        let streams = payloads.compactMap { StreamFrame.decode($0)?.stream }
        #expect(streams.first == .interactive)
        #expect(streams.contains(.files))
    }

    @Test func theStreamsTogetherStayWithinTheSharedBudget() {
        var mux = StreamMux()
        for number in 0..<200 {
            mux.enqueue(fileChunk(number))
            mux.enqueue(command(number))
        }
        let payloads = mux.outgoing(now: .now, carrier: .lossy)
        let bytes = payloads.reduce(0) { total, payload in
            guard case .data(_, let data)? = StreamFrame.decode(payload)?.pipe else { return total }
            return total + data.count
        }
        #expect(bytes <= StreamMux.lossyBudgetBytes)
    }

    @Test func aTransferDoesNotStarveACommandAddedWhileItIsInFlight() throws {
        var pair = Pair()
        for number in 0..<200 { pair.a.enqueue(fileChunk(number)) }
        try pair.step()
        pair.a.enqueue(command(7))
        try pair.step()
        try pair.step()
        #expect(pair.atB.contains(command(7)))
    }

    @Test func movingToTheReliableCarrierDeliversWhatTheLaneLost() throws {
        var pair = Pair()
        pair.lossPercent = 100
        for number in 0..<10 { pair.a.enqueue(command(number)) }
        for _ in 0..<5 { try pair.step() }
        #expect(pair.atB.isEmpty)
        pair.carrier = .reliable
        pair.a.carrierChanged()
        pair.b.carrierChanged()
        try pair.run { $0.atB.count == 10 }
        #expect(pair.atB == (0..<10).map(command))
    }

    @Test func movingBackToTheLaneDeliversWhatTheReliableCarrierHeldBack() throws {
        var pair = Pair()
        pair.carrier = .reliable
        for number in 0..<5 { pair.a.enqueue(command(number)) }
        try pair.run { $0.atB.count == 5 }
        pair.carrier = .lossy
        pair.a.carrierChanged()
        for number in 5..<10 { pair.a.enqueue(command(number)) }
        try pair.run { $0.atB.count == 10 }
        #expect(pair.atB == (0..<10).map(command))
    }

    @Test func aFrameThatNeverTravelsOnAStreamIsLeftToTheCaller() {
        var mux = StreamMux()
        let video = mux.enqueue(Frame(kind: .videoFrame, payload: Data([1])))
        let hello = mux.enqueue(Frame(kind: .clientHello, payload: Data([1])))
        let sent = mux.outgoing(now: .now, carrier: .lossy)
        #expect(!video)
        #expect(!hello)
        #expect(sent.isEmpty)
    }

    @Test func bytesThatAreNotFramesEndTheStreamLoudly() {
        var mux = StreamMux()
        // A declared length of zero is never a frame.
        let bad = StreamFrame(stream: .interactive, pipe: .data(offset: 0, payload: Data([0, 0, 0, 0, 1]))).encoded()
        var threw = false
        do { _ = try mux.receive(bad, now: .now) } catch { threw = true }
        #expect(threw)
    }
}
