import Foundation

/// The conditions a host names in ``NoticePayload/code``, so a client shows its own wording and keeps the host's sentence as a fallback.
public enum NoticeCode: String, Sendable, CaseIterable {
    case captureRecoveryFailed = "capture-recovery-failed"
    case screenRecordingDenied = "screen-recording-denied"
    case screenLocked = "screen-locked"
    case displayDisconnected = "display-disconnected"
    case screenAsleep = "screen-asleep"
    case privacyModeFailed = "privacy-mode-failed"
    case privacyModeUncovered = "privacy-mode-uncovered"
}

extension NoticePayload {
    /// Nil for a payload with no code, and for a code a newer host invented.
    public var knownCode: NoticeCode? {
        code.flatMap(NoticeCode.init(rawValue:))
    }
}
