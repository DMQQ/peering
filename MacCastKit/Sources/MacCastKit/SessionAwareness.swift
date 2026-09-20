import Foundation
import RemoteCore

/// What the app has to say when nobody is looking at it.
///
/// The decision is a value rather than a side effect: this one function is the whole rule
/// about which events are worth interrupting the user for, so what notifies — and, more
/// often, what deliberately does not — can be read and tested without an app bundle, an
/// authorization prompt or a live session.
public enum SessionAwareness {
    /// One per thing worth saying. The identifier is fixed per kind rather than per event, so
    /// a second banner of a kind replaces the first instead of stacking behind it, and so the
    /// app can take one back by name the moment it stops being true.
    public enum Kind: String, CaseIterable, Sendable {
        case connectionEnded
        case awaitingPairingCode
        case connected

        public var identifier: String { "pl.dmq.peering.session.\(rawValue)" }
    }

    public struct Notification: Equatable, Sendable {
        public let kind: Kind
        public let title: String
        public let body: String

        public var identifier: String { kind.identifier }
    }

    /// The banner for one transition, or `nil` for the transitions that deserve none.
    ///
    /// It takes the phase the session came *from* because the events worth announcing are
    /// changes of state rather than states. A Mac that is unreachable stays unreachable, and
    /// a rule that announced the phase would turn a reconnect loop into a notification loop.
    ///
    /// `deliberate` is the user's own doing, and it cannot be read off the phases: a session
    /// the user ended and one that dropped are both `.disconnected` from here. Only the
    /// caller, which watched the button, knows which of the two it was.
    public static func notification(
        from previous: ClientSession.Phase,
        to phase: ClientSession.Phase,
        hostName: String,
        deliberate: Bool
    ) -> Notification? {
        // The same phase arriving twice is not an event. This one happens in practice: the
        // model sets `.disconnected` itself and the session then reports one of its own.
        guard previous != phase else { return nil }

        switch phase {
        case .ready:
            return Notification(
                kind: .connected,
                title: "Connected to \(hostName)",
                body: "The Mac's screen is on this device now."
            )

        case .confirming:
            // The six digits are deliberately not in the body. A notification is readable on
            // a locked screen, and comparing that code against the Mac's own screen is the
            // single thing standing between this device and a Mac nobody sat down at.
            return Notification(
                kind: .awaitingPairingCode,
                title: "Pairing with \(hostName)",
                body: "The Mac is showing a six-digit code. Open Peering to check the two match."
            )

        case .failed(let message):
            // The Mac's own wording, not a summary of it: these messages say what to do next
            // ("if it was reset, forget it here and pair again") and a banner is often the
            // only place the user will ever read one.
            return Notification(
                kind: .connectionEnded,
                title: "Connection to \(hostName) failed",
                body: message
            )

        case .disconnected:
            // Nothing was connected, so nothing has been lost. The phase is also where the
            // model arrives on its way out of a session it never held, which is not news.
            guard previous.holdsSession, !deliberate else { return nil }
            return Notification(
                kind: .connectionEnded,
                title: "Connection to \(hostName) ended",
                body: "The Mac is no longer reachable from this device."
            )

        case .idle, .connecting, .handshaking:
            return nil
        }
    }
}
