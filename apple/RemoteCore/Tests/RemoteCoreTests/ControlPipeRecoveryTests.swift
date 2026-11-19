import Foundation
import Testing
@testable import RemoteCore

struct ControlPipeRecoveryTests {
    private let start = ContinuousClock.now

    private func offsets(_ frames: [ControlPipeFrame]) -> [UInt64] {
        frames.compactMap { frame in
            if case .data(let offset, _) = frame { return offset }
            return nil
        }
    }

    private func sent(segments: Int) -> ControlPipeSender {
        var sender = ControlPipeSender()
        sender.enqueue(Data(count: ControlPipeSender.maxPayload * segments))
        _ = sender.frames(now: start, carrier: .lossy)
        return sender
    }

    @Test func steadyTrafficDoesNotPostponeTheResendOfALostSegment() {
        var sender = sent(segments: 3)
        var resentAt: Duration?
        // A new byte every 50 ms, like a moving mouse, while the first segment never arrives.
        for tick in 1...40 {
            let now = start + .milliseconds(50 * tick)
            sender.enqueue(Data([1]))
            if offsets(sender.frames(now: now, carrier: .lossy)).contains(0) {
                resentAt = .milliseconds(50 * tick)
                break
            }
        }
        #expect(resentAt != nil)
        #expect((resentAt ?? .seconds(60)) <= .milliseconds(500))
    }

    @Test func aTimeoutResendsOnlyTheFirstSegment() {
        var sender = sent(segments: 5)
        let resent = sender.frames(now: start + .seconds(1), carrier: .lossy)
        #expect(offsets(resent) == [0])
    }

    @Test func threeRepeatedAcknowledgementsResendTheFirstSegmentAtOnce() {
        var sender = sent(segments: 5)
        for _ in 0..<2 { sender.acknowledge(upTo: 0, now: start + .milliseconds(100)) }
        #expect(offsets(sender.frames(now: start + .milliseconds(100), carrier: .lossy)).isEmpty)
        sender.acknowledge(upTo: 0, now: start + .milliseconds(100))
        #expect(offsets(sender.frames(now: start + .milliseconds(100), carrier: .lossy)) == [0])
    }

    @Test func aFastResendDoesNotBackOffTheTimer() {
        var sender = sent(segments: 5)
        for _ in 0..<3 { sender.acknowledge(upTo: 0, now: start + .milliseconds(100)) }
        _ = sender.frames(now: start + .milliseconds(100), carrier: .lossy)
        #expect(sender.consecutiveTimeouts == 0)
    }

    @Test func anAcknowledgementShortOfTheRepairPointResendsTheNextGapAtOnce() {
        var sender = sent(segments: 5)
        for _ in 0..<3 { sender.acknowledge(upTo: 0, now: start + .milliseconds(100)) }
        _ = sender.frames(now: start + .milliseconds(100), carrier: .lossy)
        // The first segment arrived but the second is also missing.
        sender.acknowledge(upTo: UInt64(ControlPipeSender.maxPayload), now: start + .milliseconds(150))
        let next = sender.frames(now: start + .milliseconds(150), carrier: .lossy)
        #expect(offsets(next) == [UInt64(ControlPipeSender.maxPayload)])
    }

    @Test func aReliableCarrierNeverResends() {
        var sender = ControlPipeSender()
        sender.enqueue(Data(count: 5000))
        _ = sender.frames(now: start, carrier: .reliable)
        #expect(sender.frames(now: start + .seconds(10), carrier: .reliable).isEmpty)
    }
}
