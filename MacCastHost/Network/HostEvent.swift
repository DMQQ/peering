import Foundation

/// Everything the networking layer needs to tell the UI.
///
/// The server runs off the main actor, so it emits these into a single `@Sendable` callback
/// instead of exposing mutable state. The UI layer owns the hop back to the main actor.
enum HostEvent: Sendable {
    case listening(port: UInt16)
    case stopped

    case clientConnected(clientID: String, clientName: String, detail: String)
    case clientDisconnected(clientID: String, clientName: String)

    /// The six digits to show the user. Present only during a first pairing.
    ///
    /// `isRemote` says the phone came in through the relay rather than over the local network,
    /// so the card has to say so or the request reads as a device on this Wi-Fi.
    case pairingCode(code: String, clientName: String, isRemote: Bool)
    case pairingCompleted(clientName: String, accepted: Bool)

    case failed(String)
}

/// A device connected to this Mac right now.
///
/// The ID is what everything else is keyed by (the pin store, the trusted list); the name is
/// only what the client chose to call itself. The two are not interchangeable.
struct ConnectedClient: Identifiable, Sendable, Equatable {
    /// The pinned device ID, not the display name.
    let id: String
    let name: String
    let since: Date

    /// Elapsed time since this device attached, for both the window and the menu bar.
    ///
    /// Formatted on demand, not through `Text(style: .timer)`: the menu bar menu cannot host a
    /// live view, and the two places have to agree.
    func elapsedDescription(now: Date = Date()) -> String {
        Duration.seconds(max(0, now.timeIntervalSince(since)))
            .formatted(.time(pattern: .hourMinuteSecond))
    }
}

/// A pairing currently awaiting the user's comparison, or the outcome of the last one.
struct PairingPrompt: Sendable, Equatable {
    let clientName: String
    let code: String
    /// Whether the phone arrived through the relay, so the card can say the comparison is with
    /// someone not necessarily on this network.
    var isRemote = false
}

/// The outcome of the most recent pairing attempt, shown briefly and then dismissed.
struct PairingOutcome: Sendable, Equatable {
    let clientName: String
    let accepted: Bool
}
