import Foundation
import RemoteCore

/// No single flag answers it: a drop that just landed looks identical to one whose ladder has run out, hence five facts.
public enum SessionResume {
    public enum FailureAction: Equatable, Sendable {
        case retrySilently
        case stopAndShowFailure
    }

    public static func failureAction(hasBeenReady: Bool) -> FailureAction {
        hasBeenReady ? .retrySilently : .stopAndShowFailure
    }

    /// `hasBeenReady` is carried across the dial the ladder makes, else the new object looks like a first open. The phase covers what the flags cannot: they outlive the moment they described, so a consumed `userEndedDeliberately` after Disconnect leaves a ready session that is not being put back.
    public static func isUnderWay(
        hasBeenReady: Bool,
        userEndedDeliberately: Bool,
        hasGivenUpResuming: Bool,
        isReconnecting: Bool,
        phase: ClientSession.Phase
    ) -> Bool {
        guard hasBeenReady, !userEndedDeliberately, !hasGivenUpResuming else { return false }

        switch phase {
        case .idle, .connecting, .handshaking, .confirming, .ready:
            // `.idle` is only the swap window between the ladder building a new session and its first `.connecting`; letting go there would flicker the picker. A user-started dial cannot be here, because a new target does not inherit `hasBeenReady`.
            return true
        case .failed, .disconnected:
            // A failure with nothing armed is not being put back: after the ladder runs out or the
            // user ends the session the phase never changes again, so a kept frame would stay.
            return isReconnecting
        }
    }
}
