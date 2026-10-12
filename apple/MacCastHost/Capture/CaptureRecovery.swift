import Foundation
import MacCastKit

/// Holds the state of a capture rebuild so concurrent failure reports (a stop error, then an encoder error from the same event) become one attempt. The decisions are ``CaptureRecoveryBudget``'s.
final class CaptureRecovery: @unchecked Sendable {
    enum Plan {
        case schedule(after: TimeInterval)
        case alreadyScheduled
        case giveUp(attempts: Int)
    }

    private let lock = NSLock()
    private var budget = CaptureRecoveryBudget()  // guarded by lock
    private var pending: Task<Void, Never>?  // guarded by lock
    private var gaveUp = false  // guarded by lock

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A wake or display change replaces a wait that was sized for a different failure.
    func plan(for cause: CaptureRecoveryBudget.Cause) -> Plan {
        lock.withLock {
            let replacesPending = cause == .wokeFromSleep || cause == .displaysChanged
            if pending != nil, !replacesPending { return .alreadyScheduled }
            switch budget.failed(cause, at: Self.now) {
            case .retry(let delay):
                pending?.cancel()
                return .schedule(after: delay)
            case .giveUp:
                pending = nil
                gaveUp = true
                return .giveUp(attempts: budget.attempts)
            }
        }
    }

    func hold(_ task: Task<Void, Never>) {
        lock.withLock { pending = task }
    }

    func attemptStarted() {
        lock.withLock { pending = nil }
    }

    /// The failure this rebuild answered, to be reported as recovered; nil when it answered a wake or a display change.
    func attemptSucceeded() -> CaptureRecoveryBudget.Report? {
        lock.withLock { budget.rebuildSucceeded() }
    }

    /// True once, for the first frame after a give-up, so the notice that said it failed can be taken back.
    func frameDelivered() -> Bool {
        lock.withLock {
            budget.frameDelivered(at: Self.now)
            defer { gaveUp = false }
            return gaveUp
        }
    }

    /// A client attaching asks for a fresh start.
    func reset() {
        lock.withLock {
            pending?.cancel()
            pending = nil
            budget.reset()
        }
    }
}
