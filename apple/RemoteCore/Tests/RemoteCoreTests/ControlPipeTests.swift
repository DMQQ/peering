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

/// Both halves joined by a carrier that can drop, duplicate and reorder what it is given.
private struct Link {
    var sender = ControlPipeSender()
    var receiver = ControlPipeReceiver()
    var delivered = Data()
    var clock = ContinuousClock.now
    var random = SplitMix(state: 7)
    var lossPercent = 0
    var carrier: ControlPipeSender.Carrier = .lossy

    mutating func step() {
        clock += .milliseconds(50)
        var wire = sender.frames(now: clock, carrier: carrier)
        if carrier == .lossy {
            wire = wire.filter { _ in Int.random(in: 0..<100, using: &random) >= lossPercent }
            wire.shuffle(using: &random)
            if let first = wire.first, Int.random(in: 0..<10, using: &random) == 0 { wire.append(first) }
        }
        for frame in wire {
            guard case .data(let offset, let payload) = frame else { continue }
            delivered.append(receiver.receive(offset: offset, payload: payload))
            if carrier == .reliable || Int.random(in: 0..<100, using: &random) >= lossPercent {
                sender.acknowledge(upTo: receiver.ackPoint, now: clock)
            }
        }
    }

    mutating func run(until done: (Link) -> Bool, limit: Int = 5000) {
        var steps = 0
        while !done(self), steps < limit { step(); steps += 1 }
    }
}

struct ControlPipeTests {
    private static let stream = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    @Test func aFrameSurvivesEncodingAndRejectsGarbage() {
        let data = ControlPipeFrame.data(offset: 0x0102030405, payload: Data([9, 8, 7]))
        #expect(ControlPipeFrame.decode(data.encoded()) == data)
        #expect(ControlPipeFrame.decode(ControlPipeFrame.ack(upTo: 42).encoded()) == .ack(upTo: 42))
        #expect(ControlPipeFrame.decode(Data([0, 1])) == nil)
        #expect(ControlPipeFrame.decode(Data([7, 0, 0, 0, 0, 0, 0, 0, 0])) == nil)
    }

    @Test func aCleanLossyCarrierDeliversTheStreamInOrder() {
        var link = Link()
        link.sender.enqueue(Self.stream)
        link.run { $0.delivered.count == Self.stream.count }
        #expect(link.delivered == Self.stream)
    }

    @Test func aLossyReorderingCarrierStillDeliversEveryByteOnce() {
        var link = Link()
        link.lossPercent = 30
        link.sender.enqueue(Self.stream)
        link.run { $0.delivered.count == Self.stream.count }
        #expect(link.delivered == Self.stream)
    }

    @Test func aLossyCarrierNeverHasMoreThanTheWindowInFlight() {
        var sender = ControlPipeSender()
        sender.enqueue(Data(count: 100_000))
        let frames = sender.frames(now: .now, carrier: .lossy)
        let bytes = frames.reduce(0) { total, frame in
            if case .data(_, let payload) = frame { return total + payload.count }
            return total
        }
        #expect(bytes == ControlPipeSender.lossyWindowBytes)
        #expect(sender.frames(now: .now, carrier: .lossy).isEmpty)
    }

    @Test func switchingCarrierResendsWhatTheOldOneLost() {
        var link = Link()
        link.lossPercent = 100
        link.sender.enqueue(Self.stream)
        for _ in 0..<5 { link.step() }
        #expect(link.delivered.isEmpty)
        link.carrier = .reliable
        link.sender.carrierChanged()
        link.run { $0.delivered.count == Self.stream.count }
        #expect(link.delivered == Self.stream)
    }

    @Test func switchingBackAndForthNeverDuplicatesOrSkipsBytes() {
        var link = Link()
        link.lossPercent = 20
        link.sender.enqueue(Self.stream)
        for round in 0..<40 {
            link.carrier = round % 2 == 0 ? .lossy : .reliable
            link.sender.carrierChanged()
            for _ in 0..<3 { link.step() }
        }
        link.carrier = .reliable
        link.sender.carrierChanged()
        link.run { $0.delivered.count == Self.stream.count }
        #expect(link.delivered == Self.stream)
    }

    @Test func aDeadLossyCarrierCountsTimeoutsSoTheDriverCanLeaveIt() {
        var sender = ControlPipeSender()
        sender.enqueue(Data(count: 3000))
        var clock = ContinuousClock.now
        _ = sender.frames(now: clock, carrier: .lossy)
        for _ in 0..<3 {
            clock += .seconds(4)
            #expect(!sender.frames(now: clock, carrier: .lossy).isEmpty)
        }
        #expect(sender.consecutiveTimeouts == 3)
        sender.acknowledge(upTo: 1000, now: clock)
        #expect(sender.consecutiveTimeouts == 0)
    }

    @Test func aDuplicateOrOverlappingSegmentIsNotDeliveredTwice() {
        var receiver = ControlPipeReceiver()
        #expect(receiver.receive(offset: 0, payload: Data([1, 2, 3])) == Data([1, 2, 3]))
        #expect(receiver.receive(offset: 0, payload: Data([1, 2, 3])).isEmpty)
        #expect(receiver.receive(offset: 2, payload: Data([3, 4])) == Data([4]))
        #expect(receiver.receive(offset: 6, payload: Data([7])).isEmpty)
        #expect(receiver.receive(offset: 4, payload: Data([5, 6])) == Data([5, 6, 7]))
        #expect(receiver.ackPoint == 7)
    }

    @Test func anAckBeyondWhatWasSentIsIgnored() {
        var sender = ControlPipeSender()
        sender.enqueue(Data(count: 10))
        _ = sender.frames(now: .now, carrier: .reliable)
        sender.acknowledge(upTo: 999, now: .now)
        #expect(sender.bufferedBytes == 10)
    }
}
