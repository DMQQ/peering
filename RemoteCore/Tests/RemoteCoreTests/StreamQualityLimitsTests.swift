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
