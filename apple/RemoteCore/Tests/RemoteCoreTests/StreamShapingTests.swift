import Testing
@testable import RemoteCore

struct StreamShapingTests {
    @Test func lowRateHalvesTheFrameRate() {
        #expect(StreamShaping.framesPerSecondCeiling(bitrateKbps: 2_000) == 30)
    }

    @Test func mediumRateKeepsTheRequestedFrameRate() {
        #expect(StreamShaping.framesPerSecondCeiling(bitrateKbps: 8_000) == nil)
    }

    @Test func aFullPanelOnLowRateScalesDownToHalf() {
        let scale = StreamShaping.pixelScale(bitrateKbps: 2_000, framesPerSecond: 30, nativePixels: 5_940_000)
        #expect(scale == 0.5)
    }

    @Test func aFullPanelOnMediumRateScalesPartway() {
        let scale = StreamShaping.pixelScale(bitrateKbps: 8_000, framesPerSecond: 60, nativePixels: 5_940_000)
        #expect(scale > 0.6 && scale < 0.75)
    }

    @Test func highRateKeepsFullSize() {
        let scale = StreamShaping.pixelScale(bitrateKbps: 20_000, framesPerSecond: 60, nativePixels: 5_940_000)
        #expect(scale == 1)
    }

    @Test func aSmallPanelNeverScalesBelowHalf() {
        #expect(StreamShaping.pixelScale(bitrateKbps: 100, framesPerSecond: 60, nativePixels: 2_000_000) == 0.5)
    }

    @Test func missingInputsLeaveTheSizeAlone() {
        #expect(StreamShaping.pixelScale(bitrateKbps: 0, framesPerSecond: 60, nativePixels: 1_000_000) == 1)
    }

    @Test func peakIsOneAndAHalfTimesTheAverageInBytes() {
        #expect(StreamShaping.peakBytesPerSecond(averageBitsPerSecond: 8_000_000) == 1_500_000)
    }
}
