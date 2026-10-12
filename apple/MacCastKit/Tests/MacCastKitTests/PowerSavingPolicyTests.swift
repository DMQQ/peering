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
}
