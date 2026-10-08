import Foundation
import RemoteCore

public enum SessionAwareness {
    /// The identifier is fixed per kind, so a second banner replaces the first.
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

        /// With more than one Mac open the per-kind identifier would let one Mac's banner replace another's. `nil` falls back to the kind's own.
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

    /// Takes the phase the session came from because only changes are worth announcing: a reconnect loop must not become a notification loop.
    /// `deliberate` cannot be read off the phases (ended and dropped are both `.disconnected`). `resuming` is a drop the app is already repairing, not news.
    public static func notification(
        from previous: ClientSession.Phase,
        to phase: ClientSession.Phase,
        hostName: String,
        hostID: String? = nil,
        deliberate: Bool,
        resuming: Bool = false
    ) -> Notification? {
        // The same phase twice is not an event: the model sets `.disconnected` itself and the session then reports its own.
        guard previous != phase else { return nil }

        switch phase {
        case .ready:
            // A Mac the app is quietly putting back (often after backgrounding) is not news; the user never saw it leave.
            guard !resuming else { return nil }
            return Notification(
                kind: .connected,
                title: String(localized: "Connected to \(hostName)"),
                body: String(localized: "The Mac's screen is on this device now."),
                hostID: hostID
            )

        case .confirming:
            // The code stays out of the body: a notification is readable on a locked screen, and comparing the code against the Mac's screen is the pairing safeguard.
            return Notification(
                kind: .awaitingPairingCode,
                title: String(localized: "Pairing with \(hostName)"),
                body: String(localized: "The Mac is showing a six-digit code. Open Peering to check the two match."),
                hostID: hostID
            )

        case .failed(let message):
            // A handover, not a failure: announcing it would expose a switch meant to be invisible. When the ladder runs out the phase is still `.failed` and the banner arrives then.
            guard !resuming else { return nil }

            // The Mac's own wording: it says what to do next.
            return Notification(
                kind: .connectionEnded,
                title: String(localized: "Connection to \(hostName) failed"),
                body: message,
                hostID: hostID
            )

        case .disconnected:
            // Nothing was connected; the model also arrives here leaving a session it never held.
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
