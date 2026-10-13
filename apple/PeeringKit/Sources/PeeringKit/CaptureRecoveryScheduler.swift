import Foundation

/// Which rebuild is the one currently owed, so failures reported close together become one attempt and a rebuild that was replaced or reset cannot run late. The delays and the give-up are ``CaptureRecoveryBudget``'s.
public struct CaptureRecoveryScheduler: Sendable, Equatable {
    public enum Plan: Sendable, Equatable {
        /// `token` identifies this rebuild; only the attempt carrying the current token may start.
        case schedule(after: TimeInterval, token: Int)
        case alreadyScheduled
        case giveUp(attempts: Int)
    }

    public private(set) var budget = CaptureRecoveryBudget()
    private var pendingToken: Int?
    private var lastToken = 0
    private var gaveUp = false

    public init() {}

    /// A wake or display change replaces a wait that was sized for a different failure.
    public mutating func plan(for cause: CaptureRecoveryBudget.Cause, at now: TimeInterval) -> Plan {
        let replacesPending = cause == .wokeFromSleep || cause == .displaysChanged
        if pendingToken != nil, !replacesPending { return .alreadyScheduled }
        switch budget.failed(cause, at: now) {
        case .retry(let delay):
            lastToken += 1
            pendingToken = lastToken
            return .schedule(after: delay, token: lastToken)
        case .giveUp:
            pendingToken = nil
            gaveUp = true
            return .giveUp(attempts: budget.attempts)
        }
    }

    public func isPending(_ token: Int) -> Bool { pendingToken == token }

    /// False for a rebuild that was replaced or reset while it waited, which must then do nothing.
    public mutating func attemptStarted(_ token: Int) -> Bool {
        guard pendingToken == token else { return false }
        pendingToken = nil
        return true
    }

    public mutating func attemptSucceeded() -> CaptureRecoveryBudget.Report? {
        budget.rebuildSucceeded()
    }

    /// True once, for the first frame after a give-up, so the notice that said it failed can be taken back.
    public mutating func frameDelivered(at now: TimeInterval) -> Bool {
        budget.frameDelivered(at: now)
        defer { gaveUp = false }
        return gaveUp
    }

    public mutating func reset() {
        pendingToken = nil
        budget.reset()
    }
}
