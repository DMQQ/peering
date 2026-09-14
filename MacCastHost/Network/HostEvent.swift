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

    case clientConnected(clientName: String, detail: String)
    case clientDisconnected(clientName: String)

    /// The six digits to show the user. Present only during a first pairing.
    case pairingCode(code: String, clientName: String)
    case pairingCompleted(clientName: String, accepted: Bool)

    case failed(String)
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
