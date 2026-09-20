import Foundation
import RemoteCore

/// Whether a dropped session is one the app is putting back, or one it has finished with.
///
/// **Declared here and merely asked in the app**, for the reason ``SessionAwareness`` is: it is a
/// rule about states, and a rule about states can be checked without a radio, a socket or a view.
///
/// **The phases cannot answer it, and neither can any one flag.** A first connection and a resume
/// run the same ladder, and the instant a drop lands is a state that also occurs later, when the
/// ladder has run out: `.failed`, nothing armed, a Mac that had been ready. The two look identical
/// from every single fact the session holds, which is why this takes five of them and why one of
/// them has to be carried across the dial.
public enum SessionResume {
    /// Whether this Mac is coming back.
    ///
    /// The three flags are the whole of what makes this a resume rather than a connection:
    /// `hasBeenReady` is what the ladder carries across the dial it makes (without it the new
    /// object is indistinguishable from a Mac being opened for the first time), `userEndedDeliberately`
    /// is the user's own doing, and `hasGivenUpResuming` is the ladder having run out.
    ///
    /// **The phase is here for the states the flags cannot reach.** They are durable, so they
    /// outlive the moment they described: a Consumed `userEndedDeliberately` after the user taps
    /// Disconnect leaves a session that was ready, did not give up, and is not being put back by
    /// anything, which without this would keep a dead picture on screen for ever with no way to the
    /// picker. What the phase adds is the difference between "a drop, and an attempt is coming" and
    /// "over".
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
            // `.idle` is the swap window and nothing else: the ladder's new session sits there for
            // the turn between being built and emitting its first `.connecting`, and a screen that
            // let go for that turn would flicker the picker in and straight back out. A dial the
            // user starts cannot be here, because a new target does not inherit `hasBeenReady`.
            return true
        case .failed, .disconnected:
            // **A Mac sitting at a failure with nothing armed is not being put back**, whatever it
            // did earlier. This is the state after the ladder runs out, and the state after the
            // user ends the session deliberately: in both, the phase never changes again, so if
            // the screen kept the frame nothing would ever take it down.
            return isReconnecting
        }
    }
}
