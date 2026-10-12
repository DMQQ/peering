import RemoteCore
import Testing

@testable import MacCastKit

@Suite("Streaming in Low Power Mode")
struct PowerSavingPolicyTests {
    @Test func highIsCappedToMediumInLowPowerMode() {
        #expect(PowerSavingPolicy.ceiling(.high, isLowPowerMode: true) == .medium)
    }

    @Test func lowerCeilingsAreLeftAlone() {
        #expect(PowerSavingPolicy.ceiling(.medium, isLowPowerMode: true) == .medium)
        #expect(PowerSavingPolicy.ceiling(.low, isLowPowerMode: true) == .low)
    }

    @Test func nothingChangesWithLowPowerModeOff() {
        #expect(PowerSavingPolicy.ceiling(.high, isLowPowerMode: false) == .high)
    }

    @Test func lowPowerModeAsksForThirtyFramesAndNormalLiftsTheCap() {
        #expect(PowerSavingPolicy.framesPerSecond(isLowPowerMode: true) == 30)
        #expect(PowerSavingPolicy.framesPerSecond(isLowPowerMode: false) == 120)
    }

    @Test func theRequestedRateSurvivesTheHostsClamp() {
        #expect(StreamQualityLimits.clampedFramesPerSecond(PowerSavingPolicy.framesPerSecond(isLowPowerMode: true)) == 30)
        #expect(StreamQualityLimits.clampedFramesPerSecond(PowerSavingPolicy.framesPerSecond(isLowPowerMode: false)) == 120)
    }
}

@Suite("Thinning frames to a cap")
struct FrameRateCapTests {
    private func kept(_ times: [Double], limit: Int?) -> [Double] {
        var cap = FrameRateCap(limit: limit)
        return times.filter { cap.admits(at: $0) }
    }

    private let sixty: [Double] = (0..<12).map { Double($0) / 60 }

    @Test func noLimitKeepsEverything() {
        #expect(kept(sixty, limit: nil).count == 12)
    }

    @Test func thirtyOutOfSixtyKeepsEveryOther() {
        #expect(kept(sixty, limit: 30) == stride(from: 0, to: 12, by: 2).map { Double($0) / 60 })
    }

    @Test func aCapAtTheCaptureRateDropsNothingDespiteJitter() {
        let jittered = sixty.enumerated().map { $0.element + ($0.offset.isMultiple(of: 2) ? 0.001 : -0.001) }
        #expect(kept(jittered, limit: 60).count == 12)
    }

    @Test func aClockThatGoesBackwardsStartsANewRun() {
        var cap = FrameRateCap(limit: 30)
        let first = cap.admits(at: 100)
        let afterReset = cap.admits(at: 3)
        let tooSoon = cap.admits(at: 3.001)
        #expect(first)
        #expect(afterReset)
        #expect(!tooSoon)
    }

    @Test func liftingTheCapKeepsEveryFrameAgain() {
        var cap = FrameRateCap(limit: 15)
        let first = cap.admits(at: 0)
        let dropped = cap.admits(at: 0.016)
        cap.setLimit(nil)
        let kept = cap.admits(at: 0.017)
        #expect(first)
        #expect(!dropped)
        #expect(kept)
        cap.setLimit(0)
        #expect(cap.limit == nil)
    }
}
