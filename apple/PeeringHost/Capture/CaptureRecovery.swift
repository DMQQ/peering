import Foundation
import PeeringKit

/// Holds the rebuild task for ``CaptureRecoveryScheduler``, whose tokens decide which rebuild is current.
final class CaptureRecovery: @unchecked Sendable {
    typealias Plan = CaptureRecoveryScheduler.Plan

    private let lock = NSLock()
    private var scheduler = CaptureRecoveryScheduler()  // guarded by lock
    private var task: Task<Void, Never>?  // guarded by lock

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func plan(for cause: CaptureRecoveryBudget.Cause) -> Plan {
        let (plan, replaced) = lock.withLock { () -> (Plan, Task<Void, Never>?) in
            let plan = scheduler.plan(for: cause, at: Self.now)
            guard plan != .alreadyScheduled else { return (plan, nil) }
            defer { task = nil }
            return (plan, task)
        }
        replaced?.cancel()
        return plan
    }

    /// A task for a token that was replaced or reset before it got here is cancelled instead of held.
    func hold(_ task: Task<Void, Never>, token: Int) {
        let current = lock.withLock { () -> Bool in
            guard scheduler.isPending(token) else { return false }
            self.task = task
            return true
        }
        if !current { task.cancel() }
    }

    /// False when this rebuild is no longer the one owed.
    func attemptStarted(token: Int) -> Bool {
        lock.withLock {
            guard scheduler.attemptStarted(token) else { return false }
            task = nil
            return true
        }
    }

    /// The failure this rebuild answered, to be reported as recovered; nil when it answered a wake or a display change.
    func attemptSucceeded() -> CaptureRecoveryBudget.Report? {
        lock.withLock { scheduler.attemptSucceeded() }
    }

    func frameDelivered() -> Bool {
        lock.withLock { scheduler.frameDelivered(at: Self.now) }
    }

    /// A client attaching asks for a fresh start.
    func reset() {
        let cancelled = lock.withLock { () -> Task<Void, Never>? in
            scheduler.reset()
            defer { task = nil }
            return task
        }
        cancelled?.cancel()
    }
}
