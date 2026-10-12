import Foundation

/// How many times, and how far apart, the host rebuilds a capture that died under a client, so a stream that cannot come back stops being retried instead of looping forever.
public struct CaptureRecoveryBudget: Sendable, Equatable {
    public enum Cause: Sendable, Equatable {
        case streamStopped(code: Int)
        case encoderFailed
        case wokeFromSleep
        case displaysChanged
        case startFailed
    }

    public enum Verdict: Sendable, Equatable {
        case retry(after: TimeInterval)
        case giveUp
    }

    /// ScreenCaptureKit's `userDeclined`: retrying cannot succeed until someone grants the permission and relaunches.
    public static let permissionDeniedCode = -3801

    public static let maximumAttempts = 6
    public static let firstDelay: TimeInterval = 1
    public static let longestDelay: TimeInterval = 30
    /// Frames arriving for this long after a rebuild mean it worked, and the next failure starts from a short delay again.
    public static let stableSeconds: TimeInterval = 10

    public private(set) var attempts = 0
    private var lastAttemptAt: TimeInterval?

    public init() {}

    public static func isRetryable(_ cause: Cause) -> Bool {
        if case .streamStopped(let code) = cause { return code != permissionDeniedCode }
        return true
    }

    /// 1, 2, 4, 8, 16, then 30 seconds.
    public static func delay(afterAttempts attempts: Int) -> TimeInterval {
        min(longestDelay, firstDelay * pow(2, Double(max(0, attempts))))
    }

    /// Wake and display changes are the system saying the old stream is gone, so they start over at the shortest delay rather than counting against a stream that was failing for another reason.
    public mutating func failed(_ cause: Cause, at now: TimeInterval) -> Verdict {
        guard Self.isRetryable(cause) else { return .giveUp }
        if cause == .wokeFromSleep || cause == .displaysChanged { attempts = 0 }
        guard attempts < Self.maximumAttempts else { return .giveUp }
        let delay = Self.delay(afterAttempts: attempts)
        attempts += 1
        lastAttemptAt = now
        return .retry(after: delay)
    }

    /// Called for every delivered frame; cheap.
    public mutating func frameDelivered(at now: TimeInterval) {
        guard attempts > 0, let lastAttemptAt, now - lastAttemptAt >= Self.stableSeconds else { return }
        attempts = 0
        self.lastAttemptAt = nil
    }

    public mutating func reset() {
        attempts = 0
        lastAttemptAt = nil
    }
}
