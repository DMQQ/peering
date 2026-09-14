import Foundation

/// Everything the networking layer needs to tell the UI.
///
/// The server runs entirely off the main actor, so it communicates by emitting these into a
/// single `@Sendable` callback rather than by exposing mutable state. The UI layer owns the
/// hop back to the main actor, which keeps every `await`/`Task` decision in one place instead
/// of scattered through the session state machine.
enum HostEvent: Sendable {
    case listening(port: UInt16)
    case stopped

    case clientConnected(clientID: String, clientName: String, detail: String)
    case clientDisconnected(clientID: String, clientName: String)

    /// The six digits to show the user. Present only during a first pairing.
    case pairingCode(code: String, clientName: String)
    case pairingCompleted(clientName: String, accepted: Bool)

    case failed(String)
}

/// A device connected to this Mac right now.
///
/// The ID is what everything else is keyed by — the pin store, the trusted list — and the name
/// is only what the client chose to call itself. The two are not interchangeable: the trusted
/// list used to test a *name* against a list of *IDs*, which is a comparison that cannot be
/// true, so a device that was connected read as merely trusted for as long as it was attached.
struct ConnectedClient: Identifiable, Sendable, Equatable {
    /// The pinned device ID, not the display name.
    let id: String
    let name: String
    let since: Date

    /// Elapsed time since this device attached, for both the window and the menu bar.
    ///
    /// Formatted on demand rather than shown through `Text(style: .timer)`: the menu bar menu is
    /// built once each time it opens and cannot host a live view, and having the two places
    /// disagree about how long a session has been running would be worse than neither ticking.
    func elapsedDescription(now: Date = Date()) -> String {
        Duration.seconds(max(0, now.timeIntervalSince(since)))
            .formatted(.time(pattern: .hourMinuteSecond))
    }
}

/// A pairing currently awaiting the user's comparison, or the outcome of the last one.
struct PairingPrompt: Sendable, Equatable {
    let clientName: String
    let code: String
}

/// The outcome of the most recent pairing attempt, shown briefly and then dismissed.
struct PairingOutcome: Sendable, Equatable {
    let clientName: String
    let accepted: Bool
}
