import Foundation

/// When an Allow or Deny tapped on a notification counts as delivered. Writing to the socket proves nothing: the link can drop in the window and the agent then waits for an answer that never came.
public enum ApprovalAnswerPolicy {
    /// Long enough for a relay round trip and the Mac's own work, short enough that a lost answer is reported while the person is still holding the phone.
    public static let confirmationSeconds: TimeInterval = 15

    public enum Outcome: Equatable, Sendable {
        case waiting
        /// The Mac said the approval is resolved: the only point at which the notification may go.
        case confirmed
        case failed
    }

    /// - Parameters:
    ///   - wasSent: whether the answer was handed to a ready connection at all.
    ///   - macResolved: whether the Mac has reported this approval resolved.
    ///   - sessionReady: whether the connection the answer went on is still up.
    ///   - waited: seconds since the answer was sent.
    public static func outcome(wasSent: Bool, macResolved: Bool, sessionReady: Bool, waited: TimeInterval) -> Outcome {
        guard wasSent else { return .failed }
        if macResolved { return .confirmed }
        if !sessionReady || waited >= confirmationSeconds { return .failed }
        return .waiting
    }
}
