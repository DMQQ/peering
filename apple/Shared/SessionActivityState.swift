import Foundation

/// What the session card shows, apart from ActivityKit so the Mac host builds and encodes the very type the widget decodes.
///
/// There is deliberately no free-text `detail` field: the session status string is written for the diagnostics panel, not a Lock Screen.
/// `nonisolated`: ActivityKit encodes and decodes from a `@concurrent` context, where a main-actor conformance cannot be used.
nonisolated struct SessionActivityState: Codable, Hashable {
    var phase: Phase

    /// Nil until video is flowing; the system advances `Text(startedAt, style: .timer)`, which keeps the clock right on a Lock Screen.
    var startedAt: Date?

    /// How this session is carried: nil until the handshake has decided.
    var path: Path?

    /// The Mac this card is about. It lives in the state because attributes cannot change after the request, so the card could not follow a tab.
    /// Optional so a card started by an earlier build still decodes; the views fall back to the app's name. A push from the Mac leaves it nil.
    var hostName: String?

    /// How many Macs are open, so the card can say when there is more than one.
    var sessionCount: Int?

    /// What is running on the Mac. One card lists the work rather than one card per job; what is waiting on the user comes first. Optional so older cards decode.
    var work: [Work]?

    /// ``HostKey`` of the Mac, so a card that was pushed without its name can look it up in the App Group store. Optional for the same reason.
    var hostKey: String?

    struct Work: Codable, Hashable {
        var name: String
        /// An SF Symbol, chosen on the phone: the widget does not know what a chat is.
        var symbol: String
        var state: State
        var detail: String?

        enum State: String, Codable, Hashable {
            case live
            case waiting
            case failed

            var isWaiting: Bool { self == .waiting }
        }
    }

    enum Path: String, Codable, Hashable, Sendable {
        case lan = "LAN"
        case relay = "Relay"
        case direct = "Direct"
    }

    /// Connecting, handshaking and awaiting the pairing code are one case: the Lock Screen has nothing different to say about them.
    enum Phase: String, Codable, Hashable {
        case pending
        case active
        case reconnecting

        /// Its own case rather than removing the card: a vanished card is indistinguishable from quitting and cannot offer to reconnect.
        case dropped

        /// The app went to the background and iOS froze the connection. The Mac is fine, so the card must not alarm.
        case paused
    }
}
