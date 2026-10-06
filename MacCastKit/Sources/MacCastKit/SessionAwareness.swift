import Foundation
import RemoteCore

/// What the app has to say when nobody is looking at it.
///
/// A value rather than a side effect: this one function is the whole rule about which events are
/// worth interrupting the user for, and it can be tested without an app bundle or a live session.
public enum SessionAwareness {
    /// One per thing worth saying: the identifier is fixed per kind, so a second banner of a kind
    /// replaces the first instead of stacking, and the app can take one back by name.
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
        /// The kind alone is fixed per kind on purpose, so with more than one Mac open that rule
        /// would mean "the newest news about anything": two Macs ending a session at once produce
        /// one banner about one of them, and the pairing code on the Mac nobody is sitting at is
        /// the one that loses. A `nil` identifier falls back to the kind's own.
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
    /// It takes the phase the session came *from* because the events worth announcing are changes
    /// of state rather than states. A Mac that is unreachable stays unreachable, and a rule that
    /// announced the phase would turn a reconnect loop into a notification loop.
    ///
    /// `deliberate` is the user's own doing and cannot be read off the phases: a session the user
    /// ended and one that dropped are both `.disconnected` from here. `resuming` is a drop the app
    /// is already putting back on its own, and a Mac being retried is not news.
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
            // Same rule as `.failed`: a Mac the app is quietly putting back on its own, most often
            // after the background/foreground cycle tears the socket down, is not news either. The
            // user never saw it leave, so telling them it arrived is telling them about a trip they
            // did not know their Mac took.
            guard !resuming else { return nil }
            return Notification(
                kind: .connected,
                title: String(localized: "Connected to \(hostName)"),
                body: String(localized: "The Mac's screen is on this device now."),
                hostID: hostID
            )

        case .confirming:
            // The six digits are deliberately not in the body: a notification is readable on a
            // locked screen, and comparing that code against the Mac's own screen is the single
            // thing standing between this device and a Mac nobody sat down at.
            return Notification(
                kind: .awaitingPairingCode,
                title: String(localized: "Pairing with \(hostName)"),
                body: String(localized: "The Mac is showing a six-digit code. Open Peering to check the two match."),
                hostID: hostID
            )

        case .failed(let message):
            // Not a failure, a handover: the app is already dialling this Mac again, and saying so
            // would be the one visible trace of a switch that is meant to be invisible. When the
            // ladder runs out the phase is still `.failed` and the retry is no longer running, so
            // the banner arrives then, which is the moment it is true.
            guard !resuming else { return nil }

            // The Mac's own wording, not a summary of it: these messages say what to do next, and a
            // banner is often the only place the user will ever read one.
            return Notification(
                kind: .connectionEnded,
                title: String(localized: "Connection to \(hostName) failed"),
                body: message,
                hostID: hostID
            )

        case .disconnected:
            // Nothing was connected, so nothing has been lost, and this is also where the model
            // arrives on its way out of a session it never held.
            guard previous.holdsSession, !deliberate else { return nil }
            return Notification(
                kind: .connectionEnded,
                title: String(localized: "Connection to \(hostName) ended"),
                body: String(localized: "The Mac is no longer reachable from this device."),
                hostID: hostID
            )

        case .idle, .connecting, .handshaking:
            return nil
        }
    }
}
