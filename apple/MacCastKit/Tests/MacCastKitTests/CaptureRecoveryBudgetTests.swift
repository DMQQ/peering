import Testing
@testable import MacCastKit

struct CaptureRecoveryBudgetTests {
    @Test func delaysDoubleFromOneSecondAndStopAtThirty() {
        #expect(CaptureRecoveryBudget.delay(afterAttempts: 0) == 1)
        #expect(CaptureRecoveryBudget.delay(afterAttempts: 1) == 2)
        #expect(CaptureRecoveryBudget.delay(afterAttempts: 4) == 16)
        #expect(CaptureRecoveryBudget.delay(afterAttempts: 5) == 30)
        #expect(CaptureRecoveryBudget.delay(afterAttempts: 40) == 30)
    }

    @Test func aStoppedStreamIsRetriedUntilTheBudgetIsSpent() {
        var budget = CaptureRecoveryBudget()
        for expected in [1.0, 2, 4, 8, 16, 30] {
            let result1 = budget.failed(.streamStopped(code: -3821), at: 0) == .retry(after: expected)
            #expect(result1)
        }
        let result2 = budget.failed(.streamStopped(code: -3821), at: 0)
        #expect(result2 == .giveUp)
    }

    @Test func aRebuildThatWorksOwesTheFailureThatCausedIt() {
        var budget = CaptureRecoveryBudget()
        _ = budget.failed(.streamStopped(code: -3821), at: 0)
        let report = budget.rebuildSucceeded()
        #expect(report == .init(code: .captureStopped, stage: "stream", errorCode: -3821))
        #expect(budget.rebuildSucceeded() == nil)
    }

    @Test func aWakeThatStartsARebuildLeavesTheEarlierFailureToBeReported() {
        var budget = CaptureRecoveryBudget()
        _ = budget.failed(.encoderFailed, at: 0)
        _ = budget.failed(.wokeFromSleep, at: 1)
        #expect(budget.rebuildSucceeded() == .init(code: .encoderFailed, stage: "encode", errorCode: nil))
    }

    @Test func aRebuildAfterOnlyAWakeOrADisplayChangeReportsNothing() {
        var budget = CaptureRecoveryBudget()
        _ = budget.failed(.displaysChanged, at: 0)
        #expect(budget.rebuildSucceeded() == nil)
    }

    @Test func givingUpDropsTheReportSoTheFailureIsNotAlsoClaimedAsRecovered() {
        var budget = CaptureRecoveryBudget()
        for _ in 0..<CaptureRecoveryBudget.maximumAttempts { _ = budget.failed(.startFailed, at: 0) }
        let verdict = budget.failed(.startFailed, at: 0)
        #expect(verdict == .giveUp)
        #expect(budget.rebuildSucceeded() == nil)
    }

    @Test func aDeniedPermissionIsNeverRetried() {
        var budget = CaptureRecoveryBudget()
        let result3 = budget.failed(.streamStopped(code: -3801), at: 0)
        #expect(result3 == .giveUp)
        #expect(budget.attempts == 0)
    }

    @Test func framesFlowingForTenSecondsRestoreTheBudget() {
        var budget = CaptureRecoveryBudget()
        _ = budget.failed(.encoderFailed, at: 100)
        _ = budget.failed(.encoderFailed, at: 102)
        budget.frameDelivered(at: 105)
        #expect(budget.attempts == 2)
        budget.frameDelivered(at: 112)
        #expect(budget.attempts == 0)
        let result4 = budget.failed(.encoderFailed, at: 113) == .retry(after: 1)
        #expect(result4)
    }

    @Test func wakeStartsOverEvenWhenTheBudgetWasSpent() {
        var budget = CaptureRecoveryBudget()
        for _ in 0..<CaptureRecoveryBudget.maximumAttempts { _ = budget.failed(.startFailed, at: 0) }
        let result5 = budget.failed(.startFailed, at: 0)
        #expect(result5 == .giveUp)
        let result6 = budget.failed(.wokeFromSleep, at: 50) == .retry(after: 1)
        #expect(result6)
    }
}

struct FailureLogGateTests {
    @Test func theFirstFailureIsLoggedAndTheRestOfTheIntervalIsCounted() {
        var gate = FailureLogGate(interval: 5)
        let result7 = gate.admit(at: 0) == .log(suppressed: 0)
        #expect(result7)
        let result8 = gate.admit(at: 1)
        #expect(result8 == .suppress)
        let result9 = gate.admit(at: 4.9)
        #expect(result9 == .suppress)
        let result10 = gate.admit(at: 5) == .log(suppressed: 2)
        #expect(result10)
        let result11 = gate.admit(at: 5.1)
        #expect(result11 == .suppress)
    }
}
