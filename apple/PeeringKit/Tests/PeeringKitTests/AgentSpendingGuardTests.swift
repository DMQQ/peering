import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

@Suite("Agent spending guard")
struct AgentSpendingGuardTests {
    @Test("cost at or past the cap is an overrun, below it is not")
    func cost() {
        let cap = AgentSpendingCap(costUSD: 2)
        #expect(AgentSpendingGuard.overrun(cap: cap, usage: AgentUsage(costUSD: 1.99)) == nil)
        #expect(AgentSpendingGuard.overrun(cap: cap, usage: AgentUsage(costUSD: 2.5)) == .cost(spentUSD: 2.5, capUSD: 2))
    }

    @Test("context past its percentage is an overrun")
    func context() {
        let cap = AgentSpendingCap(contextPercent: 70)
        let usage = AgentUsage(contextUsedTokens: 150_000, contextWindowTokens: 200_000)
        #expect(AgentSpendingGuard.overrun(cap: cap, usage: usage) == .context(percent: 75, capPercent: 70))
        #expect(AgentSpendingGuard.holdsQueue(cap: cap, usage: usage))
    }

    @Test("no cap, no usage, or a figure the CLI never reported holds nothing")
    func unknown() {
        #expect(!AgentSpendingGuard.holdsQueue(cap: nil, usage: AgentUsage(costUSD: 100)))
        #expect(!AgentSpendingGuard.holdsQueue(cap: AgentSpendingCap(costUSD: 1), usage: nil))
        #expect(!AgentSpendingGuard.holdsQueue(cap: AgentSpendingCap(costUSD: 1, contextPercent: 10), usage: AgentUsage()))
    }

    @Test("typed caps parse only as positive numbers and percentages from 1 to 100")
    func parsing() {
        let english = Locale(identifier: "en_US")
        #expect(AgentSpendingGuard.parsedCost("$5", locale: english) == 5)
        #expect(AgentSpendingGuard.parsedCost("2.5", locale: english) == 2.5)
        #expect(AgentSpendingGuard.parsedCost("2,5", locale: Locale(identifier: "pl_PL")) == 2.5)
        #expect(AgentSpendingGuard.parsedCost("0", locale: english) == nil)
        #expect(AgentSpendingGuard.parsedCost("", locale: english) == nil)
        #expect(AgentSpendingGuard.parsedPercent("80%") == 80)
        #expect(AgentSpendingGuard.parsedPercent("0") == nil)
        #expect(AgentSpendingGuard.parsedPercent("101") == nil)
    }

    @Test("the cap travels as optional fields, so an empty one decodes from an empty object")
    func wire() throws {
        let decoded = try JSONDecoder().decode(AgentSpendingCap.self, from: Data("{}".utf8))
        #expect(decoded.isEmpty)
    }
}

@Suite("Agent five-hour limit warning")
struct AgentLimitWarningTests {
    private let resets = Date(timeIntervalSince1970: 1_800_000_000)

    private func limits(_ fraction: Double, resetsAt: Date? = nil) -> [AgentUsageLimit] {
        [AgentUsageLimit(label: "5 hours", usedFraction: fraction, resetsAt: resetsAt ?? resets)]
    }

    @Test("nothing below 80 percent, then 80, then 95")
    func thresholds() {
        #expect(AgentLimitWarning.current(in: limits(0.79)) == nil)
        #expect(AgentLimitWarning.current(in: limits(0.8))?.percent == 80)
        #expect(AgentLimitWarning.current(in: limits(0.96))?.percent == 95)
    }

    @Test("each threshold is given once per window, and a new window starts again")
    func oncePerWindow() {
        var given: Set<String> = []
        #expect(AgentLimitWarning.due(in: limits(0.82), given: &given)?.percent == 80)
        #expect(AgentLimitWarning.due(in: limits(0.85), given: &given) == nil)
        #expect(AgentLimitWarning.due(in: limits(0.95), given: &given)?.percent == 95)
        #expect(AgentLimitWarning.due(in: limits(0.99), given: &given) == nil)
        let next = resets.addingTimeInterval(5 * 3600)
        #expect(AgentLimitWarning.due(in: limits(0.81, resetsAt: next), given: &given)?.percent == 80)
    }

    @Test("other windows are not the five-hour one")
    func otherWindows() {
        let weekly = [AgentUsageLimit(label: "7 days", usedFraction: 0.99)]
        #expect(AgentLimitWarning.current(in: weekly) == nil)
    }
}

@Suite("Agent alert policy")
struct AgentAlertPolicyTests {
    @Test("decisions only lets approvals through and holds back finished and failed turns")
    func decisionsOnly() {
        #expect(AgentAlertPolicy.allows(.decision, decisionsOnly: true))
        #expect(!AgentAlertPolicy.allows(.finished, decisionsOnly: true))
        #expect(!AgentAlertPolicy.allows(.failed, decisionsOnly: true))
        #expect(AgentAlertPolicy.allows(.finished, decisionsOnly: false))
    }
}
