import RemoteCore
import Testing

@testable import MacCastKit

@Suite struct AgentContextMeterTests {
    @Test func theFractionIsUsedOverWindow() {
        #expect(AgentContextMeter.fraction(used: 50_000, window: 200_000) == 0.25)
    }

    @Test func nothingIsShownUntilBothNumbersAreKnown() {
        #expect(AgentContextMeter.fraction(used: nil, window: 200_000) == nil)
        #expect(AgentContextMeter.fraction(used: 1_000, window: nil) == nil)
        #expect(AgentContextMeter.fraction(used: 1_000, window: 0) == nil)
    }

    @Test func aContextOverTheWindowStopsAtFull() {
        #expect(AgentContextMeter.fraction(used: 250_000, window: 200_000) == 1)
    }

    @Test func eightyPercentIsNearlyFull() {
        #expect(AgentContextMeter.isNearlyFull(0.8))
        #expect(!AgentContextMeter.isNearlyFull(0.79))
        #expect(AgentContextMeter.percent(0.666) == 67)
    }
}

@Suite struct AgentContextLabelTests {
    @Test func tokensReadInKAndM() {
        #expect(AgentContextMeter.tokens(950) == "950")
        #expect(AgentContextMeter.tokens(70_400) == "70k")
        #expect(AgentContextMeter.tokens(200_000) == "200k")
        #expect(AgentContextMeter.tokens(1_000_000) == "1M")
        #expect(AgentContextMeter.tokens(1_250_000) == "1.2M")
    }

    @Test func theLabelPairsUsedWithTheWindow() {
        #expect(AgentContextMeter.label(used: 70_000, window: 1_000_000) == "70k / 1M")
    }

    @Test func onlyTheFiveHourWindowIsPicked() {
        let limits = [AgentUsageLimit(label: "7 days", usedFraction: 0.9), AgentUsageLimit(label: "5 hours", usedFraction: 0.4)]
        #expect(AgentContextMeter.fiveHour(in: limits)?.usedFraction == 0.4)
        #expect(AgentContextMeter.fiveHour(in: [limits[0]]) == nil)
    }
}
