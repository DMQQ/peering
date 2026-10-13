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

    /// What a failure looks like in the host's error event.
    public struct Report: Sendable, Equatable {
        public let code: HostEventCodes.ErrorCode
        public let stage: HostEventCodes.ErrorStage
        public let errorCode: Int?
    }

    public private(set) var attempts = 0
    private var lastAttemptAt: TimeInterval?
    /// The failure the pending rebuild answers, kept until the rebuild works or the budget runs out.
    private var pendingReport: Report?

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
        guard Self.isRetryable(cause) else { return giveUp() }
        if cause == .wokeFromSleep || cause == .displaysChanged { attempts = 0 }
        guard attempts < Self.maximumAttempts else { return giveUp() }
        let delay = Self.delay(afterAttempts: attempts)
        attempts += 1
        lastAttemptAt = now
        pendingReport = Self.report(for: cause) ?? pendingReport
        return .retry(after: delay)
    }

    /// The error to report once a rebuild has worked, with `recovered: true`. Nil when the rebuild answered only a wake or a display change, where nothing had failed.
    public mutating func rebuildSucceeded() -> Report? {
        defer { pendingReport = nil }
        return pendingReport
    }

    /// Wake and display changes are the system moving, not a fault, so they have no report.
    public static func report(for cause: Cause) -> Report? {
        switch cause {
        case .streamStopped(let code): Report(code: .captureStopped, stage: .stream, errorCode: code)
        case .encoderFailed: Report(code: .encoderFailed, stage: .encode, errorCode: nil)
        case .startFailed: Report(code: .captureFailed, stage: .start, errorCode: nil)
        case .wokeFromSleep, .displaysChanged: nil
        }
    }

    /// The failure is reported by whoever tells the user it could not be restored, with `recovered: false`.
    private mutating func giveUp() -> Verdict {
        pendingReport = nil
        return .giveUp
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
        pendingReport = nil
    }
}
