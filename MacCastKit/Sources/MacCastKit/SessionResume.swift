import Foundation
import RemoteCore

/// Whether a dropped session is one the app is putting back, or one it has finished with.
///
/// No single flag answers it: a drop that just landed looks identical to one whose ladder has run
/// out, which is why this takes five facts, one of which is carried across the dial.
public enum SessionResume {
    /// What a failed connection that the app started on its own means.
    public enum FailureAction: Equatable, Sendable {
        case retrySilently
        case stopAndShowFailure
    }

    public static func failureAction(hasBeenReady: Bool) -> FailureAction {
        hasBeenReady ? .retrySilently : .stopAndShowFailure
    }

    /// Whether this Mac is coming back.
    ///
    /// `hasBeenReady` is what the ladder carries across the dial it makes, without which the new
    /// object is indistinguishable from a Mac being opened for the first time; `userEndedDeliberately`
    /// is the user's own doing and `hasGivenUpResuming` is the ladder having run out.
    ///
    /// The phase covers the states the flags cannot reach: they are durable and outlive the moment
    /// they described, so a Consumed `userEndedDeliberately` after the user taps Disconnect leaves
    /// a session that was ready, did not give up, and is not being put back.
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
            // `.idle` is the swap window and nothing else: the turn between the ladder's new
            // session being built and emitting its first `.connecting`, where a screen that let go
            // would flicker the picker in and out. A dial the user starts cannot be here, because a
            // new target does not inherit `hasBeenReady`.
            return true
        case .failed, .disconnected:
            // A failure with nothing armed is not being put back: after the ladder runs out or the
            // user ends the session the phase never changes again, so a kept frame would stay.
            return isReconnecting
        }
    }
}
