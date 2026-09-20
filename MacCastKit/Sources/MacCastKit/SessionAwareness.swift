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

        /// Which Mac the banner is about, where the caller knows.
        ///
        /// **The half of the identifier that several Macs made necessary.** The kind alone is
        /// fixed per kind on purpose — a second banner of a kind should replace the first rather
        /// than stack behind it — but with more than one Mac open that rule stops meaning "the
        /// newest news about this" and starts meaning "the newest news about anything": two Macs
        /// ending a session at the same moment produce one banner about one of them, and the
        /// pairing code on the Mac nobody is sitting at is the one that loses.
        ///
        /// Optional, and a `nil` identifier falls back to the kind's own, so a caller with no Mac
        /// in hand is no worse off than before.
        public let hostID: String?

        public init(kind: Kind, title: String, body: String, hostID: String? = nil) {
            self.kind = kind
            self.title = title
            self.body = body
            self.hostID = hostID
        }

        public var identifier: String {
            guard let hostID, !hostID.isEmpty else { return kind.identifier }
            return "\(kind.identifier).\(hostID)"
        }
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
    /// `resuming` is a drop the app is already putting back on its own. It is the third thing the
    /// phases cannot say for themselves, beside `deliberate`, and it is here for the same reason:
    /// a Mac that has dropped and is being retried is not news, because the thing the user would do
    /// about a banner is the thing the ladder is already doing. A network switch that recovers in
    /// two seconds should not have told them anything, and with no indicator on screen the banner
    /// was the only thing left that did.
    ///
    /// Defaulted rather than required so that the callers which cannot be a resume say nothing
    /// about it, and the one that can has to pass it.
    public static func notification(
        from previous: ClientSession.Phase,
        to phase: ClientSession.Phase,
        hostName: String,
        hostID: String? = nil,
        deliberate: Bool,
        resuming: Bool = false
    ) -> Notification? {
        // The same phase arriving twice is not an event. This one happens in practice: the
        // model sets `.disconnected` itself and the session then reports one of its own.
        guard previous != phase else { return nil }

        switch phase {
        case .ready:
            return Notification(
                kind: .connected,
                title: "Connected to \(hostName)",
                body: "The Mac's screen is on this device now.",
                hostID: hostID
            )

        case .confirming:
            // The six digits are deliberately not in the body. A notification is readable on
            // a locked screen, and comparing that code against the Mac's own screen is the
            // single thing standing between this device and a Mac nobody sat down at.
            return Notification(
                kind: .awaitingPairingCode,
                title: "Pairing with \(hostName)",
                body: "The Mac is showing a six-digit code. Open Peering to check the two match.",
                hostID: hostID
            )

        case .failed(let message):
            // Not a failure, a handover. See `resuming` above: the app is already dialling this
            // Mac again, so there is nothing here for the user to do, and saying so would be the
            // one visible trace of a switch that is meant to be invisible. When the ladder does
            // run out the phase is still `.failed` and the retry is no longer running, so the
            // banner arrives then, which is the moment it is true.
            guard !resuming else { return nil }

            // The Mac's own wording, not a summary of it: these messages say what to do next
            // ("if it was reset, forget it here and pair again") and a banner is often the
            // only place the user will ever read one.
            return Notification(
                kind: .connectionEnded,
                title: "Connection to \(hostName) failed",
                body: message,
                hostID: hostID
            )

        case .disconnected:
            // Nothing was connected, so nothing has been lost. The phase is also where the
            // model arrives on its way out of a session it never held, which is not news.
            guard previous.holdsSession, !deliberate else { return nil }
            return Notification(
                kind: .connectionEnded,
                title: "Connection to \(hostName) ended",
                body: "The Mac is no longer reachable from this device.",
                hostID: hostID
            )

        case .idle, .connecting, .handshaking:
            return nil
        }
    }
}
