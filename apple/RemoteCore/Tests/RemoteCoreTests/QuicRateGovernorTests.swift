import Testing

@testable import RemoteCore

struct QuicRateGovernorTests {
    private func reading(ceiling: Int = 30_000, backlog: Int = 0, delivered: UInt64 = 0, bandwidth: UInt64 = 0) -> QuicRateGovernor.Reading {
        .init(ceilingKbps: ceiling, backlogBytes: backlog, deliveryRateBytesPerSecond: delivered, bandwidthBytesPerSecond: bandwidth)
    }

    @Test("a queue drops the bitrate at once to below what the link delivered")
    func aQueueBacksOffBelowTheDeliveredRate() {
        var governor = QuicRateGovernor(startingKbps: 30_000)
        // 1.25 MB/s delivered is 10 Mbit/s; a 400 KB backlog is far past 40 ms of it.
        let changed = governor.decide(reading(backlog: 400_000, delivered: 1_250_000, bandwidth: 1_250_000))
        #expect(changed == 7_000)
        #expect(governor.targetKbps == 7_000)
    }

    @Test("with no queue the bitrate climbs gradually and stops at the user's ceiling")
    func climbsToTheCeiling() {
        var governor = QuicRateGovernor(startingKbps: 5_000)
        _ = governor.decide(reading(ceiling: 8_000))
        #expect(governor.targetKbps == 5_500)
        for _ in 0..<20 { _ = governor.decide(reading(ceiling: 8_000)) }
        #expect(governor.targetKbps == 8_000)
    }

    @Test("a backlog within the tolerated sending time is not a queue")
    func aSmallBacklogIsTolerated() {
        var governor = QuicRateGovernor(startingKbps: 20_000)
        // 40 ms of 10 MB/s is 400 KB.
        _ = governor.decide(reading(backlog: 300_000, delivered: 10_000_000, bandwidth: 10_000_000))
        #expect(governor.targetKbps > 20_000)
    }

    @Test("the bitrate never goes below the floor, even when nothing was measured")
    func neverBelowTheFloor() {
        var governor = QuicRateGovernor(startingKbps: 1_200)
        for _ in 0..<10 { _ = governor.decide(reading(backlog: 1_000_000)) }
        #expect(governor.targetKbps == QuicRateGovernor.floorKbps)
    }

    @Test("lowering the ceiling takes effect on the next decision")
    func aLowerCeilingAppliesAtOnce() {
        var governor = QuicRateGovernor(startingKbps: 30_000)
        #expect(governor.decide(reading(ceiling: 6_000)) == 6_000)
    }

    @Test("a change too small to matter is not reported")
    func smallStepsAreNotReported() {
        var governor = QuicRateGovernor(startingKbps: 7_900)
        #expect(governor.decide(reading(ceiling: 8_000)) == nil)
        #expect(governor.targetKbps == 8_000)
    }
}
