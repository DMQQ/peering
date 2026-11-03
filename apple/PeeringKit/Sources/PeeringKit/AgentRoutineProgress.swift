import Foundation
import RemoteCore

/// Where a routine's run has got to, read from its chat.
public enum AgentRoutineProgress: Equatable, Sendable {
    case running
    /// Over the routine's own time limit: the Mac stops the turn and records the run as stopped.
    case overTime
    case ended(AgentRoutineRun.Outcome)

    /// A chat that was never seen working and has stayed idle this long did not start its turn.
    public static let startGrace: TimeInterval = 10 * 60

    /// - Parameters:
    ///   - state: the chat's state, nil when the chat is gone.
    ///   - finishedOK: how the chat's last turn ended, nil while no turn has.
    public static func of(
        state: AgentSessionState?,
        finishedOK: Bool?,
        startedAt: Date,
        now: Date,
        stopAfterMinutes: Int?
    ) -> AgentRoutineProgress {
        guard let state else { return .ended(.stopped) }
        if let limit = stopAfterMinutes, now.timeIntervalSince(startedAt) >= TimeInterval(limit * 60) {
            return state == .working || state == .awaitingApproval ? .overTime : .ended(outcome(finishedOK))
        }
        switch state {
        case .working, .awaitingApproval:
            return .running
        case .failed:
            return .ended(.failed)
        case .exited:
            return .ended(outcome(finishedOK))
        case .idle:
            if let finishedOK { return .ended(finishedOK ? .succeeded : .failed) }
            return now.timeIntervalSince(startedAt) >= startGrace ? .ended(.failed) : .running
        }
    }

    private static func outcome(_ finishedOK: Bool?) -> AgentRoutineRun.Outcome {
        finishedOK == true ? .succeeded : .failed
    }
}
