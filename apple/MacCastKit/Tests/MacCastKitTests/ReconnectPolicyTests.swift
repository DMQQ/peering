import Foundation
import Testing

@testable import MacCastKit

struct ReconnectPolicyTests {
    private let start = Date(timeIntervalSince1970: 5_000)

    @Test func delaysGrowWithEachFailureAndStopAtTheLast() {
        var policy = ReconnectPolicy()
        let bases = (0..<7).map { _ in policy.delayAfterEnd(at: start, jitter: 0) / 1.2 }
        #expect(bases.map { $0.rounded() } == [1, 2, 5, 10, 30, 30, 30])
    }

    @Test func jitterAddsTwentyToFiftyPercent() {
        var low = ReconnectPolicy()
        var high = ReconnectPolicy()
        #expect(abs(low.delayAfterEnd(at: start, jitter: 0) - 1.2) < 0.000_001)
        #expect(abs(high.delayAfterEnd(at: start, jitter: 1) - 1.5) < 0.000_001)
    }

    @Test func aRegistrationThatDropsAtOnceDoesNotResetTheBackoff() {
        var policy = ReconnectPolicy()
        _ = policy.delayAfterEnd(at: start, jitter: 0)
        _ = policy.delayAfterEnd(at: start, jitter: 0)

        policy.registered(at: start)
        let delay = policy.delayAfterEnd(at: start.addingTimeInterval(2), jitter: 0)
        #expect(abs(delay - 5 * 1.2) < 0.000_001)
    }

    @Test func aRegistrationThatStayedUpResetsTheBackoff() {
        var policy = ReconnectPolicy()
        _ = policy.delayAfterEnd(at: start, jitter: 0)
        _ = policy.delayAfterEnd(at: start, jitter: 0)

        policy.registered(at: start)
        let delay = policy.delayAfterEnd(at: start.addingTimeInterval(61), jitter: 0)
        #expect(abs(delay - 1 * 1.2) < 0.000_001)
    }

    @Test func aSecondRegisteredMessageDoesNotRestartTheClock() {
        var policy = ReconnectPolicy()
        _ = policy.delayAfterEnd(at: start, jitter: 0)

        policy.registered(at: start)
        policy.registered(at: start.addingTimeInterval(50))
        let delay = policy.delayAfterEnd(at: start.addingTimeInterval(61), jitter: 0)
        #expect(abs(delay - 1.2) < 0.000_001)
    }

    @Test func aJitterOutsideTheUnitRangeIsClamped() {
        var policy = ReconnectPolicy()
        #expect(abs(policy.delayAfterEnd(at: start, jitter: 9) - 1.5) < 0.000_001)
    }
}

struct SignallingLivenessTests {
    @Test func twoUnansweredPingsAreTolerated() {
        var liveness = SignallingLiveness()
        #expect(liveness.pingDue() == false)
        #expect(liveness.pingDue() == false)
        #expect(liveness.pingDue() == true)
    }

    @Test func anythingHeardClearsTheCount() {
        var liveness = SignallingLiveness()
        _ = liveness.pingDue()
        _ = liveness.pingDue()
        liveness.heard()
        #expect(liveness.pingDue() == false)
        #expect(liveness.pingDue() == false)
        #expect(liveness.pingDue() == true)
    }
}
