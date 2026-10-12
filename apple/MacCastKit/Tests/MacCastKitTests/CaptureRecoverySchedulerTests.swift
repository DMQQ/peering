import Testing
@testable import MacCastKit

struct CaptureRecoverySchedulerTests {
    private let stopped = CaptureRecoveryBudget.Cause.streamStopped(code: -3821)

    @Test func twoQuickFailuresScheduleExactlyOneRebuild() {
        var scheduler = CaptureRecoveryScheduler()
        let first = scheduler.plan(for: stopped, at: 0)
        let second = scheduler.plan(for: .encoderFailed, at: 0.01)
        #expect(first == .schedule(after: 1, token: 1))
        #expect(second == .alreadyScheduled)
        #expect(scheduler.budget.attempts == 1)
    }

    @Test func aWakeReplacesTheWaitAndTheOldAttemptMayNotStart() {
        var scheduler = CaptureRecoveryScheduler()
        _ = scheduler.plan(for: stopped, at: 0)
        let replacement = scheduler.plan(for: .wokeFromSleep, at: 1)
        #expect(replacement == .schedule(after: 1, token: 2))
        let stale = scheduler.attemptStarted(1)
        #expect(stale == false)
        let started = scheduler.attemptStarted(2)
        #expect(started)
    }

    @Test func aStaleAttemptLeavesTheReplacementPending() {
        var scheduler = CaptureRecoveryScheduler()
        _ = scheduler.plan(for: stopped, at: 0)
        _ = scheduler.plan(for: .displaysChanged, at: 1)
        _ = scheduler.attemptStarted(1)
        #expect(scheduler.isPending(2))
        let planned = scheduler.plan(for: stopped, at: 2)
        #expect(planned == .alreadyScheduled)
    }

    @Test func resetCancelsARebuildThatIsPastItsSleep() {
        var scheduler = CaptureRecoveryScheduler()
        _ = scheduler.plan(for: stopped, at: 0)
        scheduler.reset()
        let stale = scheduler.attemptStarted(1)
        #expect(stale == false)
        #expect(scheduler.budget.attempts == 0)
    }

    @Test func aStartedAttemptFreesTheNextFailureToSchedule() {
        var scheduler = CaptureRecoveryScheduler()
        _ = scheduler.plan(for: stopped, at: 0)
        let started = scheduler.attemptStarted(1)
        #expect(started)
        let planned = scheduler.plan(for: .startFailed, at: 1)
        #expect(planned == .schedule(after: 2, token: 2))
    }

    @Test func theGiveUpNoticeIsTakenBackByTheFirstFrameOnly() {
        var scheduler = CaptureRecoveryScheduler()
        for token in 1...CaptureRecoveryBudget.maximumAttempts {
            _ = scheduler.plan(for: stopped, at: 0)
            _ = scheduler.attemptStarted(token)
        }
        let planned = scheduler.plan(for: stopped, at: 0)
        #expect(planned == .giveUp(attempts: CaptureRecoveryBudget.maximumAttempts))
        let first = scheduler.frameDelivered(at: 1)
        let second = scheduler.frameDelivered(at: 2)
        #expect(first)
        #expect(second == false)
    }
}
