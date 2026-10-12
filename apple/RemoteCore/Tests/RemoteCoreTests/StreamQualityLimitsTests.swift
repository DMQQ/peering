import Testing
@testable import RemoteCore

struct StreamQualityLimitsTests {
    @Test func rejectsNonPositiveBitrates() {
        #expect(StreamQualityLimits.clampedBitrateKbps(0) == nil)
        #expect(StreamQualityLimits.clampedBitrateKbps(-5) == nil)
        #expect(StreamQualityLimits.clampedBitrateKbps(Int.min) == nil)
    }

    @Test func capsAHugeBitrateSoTheBitsPerSecondProductCannotOverflow() {
        #expect(StreamQualityLimits.clampedBitrateKbps(Int.max) == 100_000)
        #expect(StreamQualityLimits.clampedBitrateKbps(8_000) == 8_000)
    }

    @Test func zeroOrNegativeFramesPerSecondMeansKeepCurrent() {
        #expect(StreamQualityLimits.clampedFramesPerSecond(0) == nil)
        #expect(StreamQualityLimits.clampedFramesPerSecond(-30) == nil)
        #expect(StreamQualityLimits.clampedFramesPerSecond(Int.min) == nil)
    }

    @Test func framesPerSecondStaysInASaneRange() {
        #expect(StreamQualityLimits.clampedFramesPerSecond(1) == 15)
        #expect(StreamQualityLimits.clampedFramesPerSecond(30) == 30)
        #expect(StreamQualityLimits.clampedFramesPerSecond(240) == 120)
        #expect(StreamQualityLimits.clampedFramesPerSecond(Int.max) == 120)
    }
}

struct FieldSelectionTests {
    private func state(_ location: Int, _ length: Int) -> FieldState {
        FieldState(text: "hello", selectionLocation: location, selectionLength: length, caret: nil)
    }

    @Test func aSelectionOutsideTheTextIsPulledInside() {
        #expect(state(-1, 2).selection(inTextOfLength: 5) == (0, 2))
        #expect(state(2, -4).selection(inTextOfLength: 5) == (2, 0))
        #expect(state(9, 3).selection(inTextOfLength: 5) == (5, 0))
        #expect(state(Int.min, Int.max).selection(inTextOfLength: 5) == (0, 5))
    }
}
