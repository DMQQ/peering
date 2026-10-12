import Foundation

/// Everything the networking layer needs to tell the UI.
enum HostEvent: Sendable {
    case listening(port: UInt16)
    case stopped

    case clientConnected(clientID: String, clientName: String, viaRelay: Bool, detail: String)
    case clientDisconnected(clientID: String, clientName: String)

    /// The six digits to show the user. Present only during a first pairing. The session id says which connection the prompt belongs to, since a name is not an identity.
    case pairingCode(sessionID: UUID, code: String, secret: Data, clientName: String, isRemote: Bool)
    /// A pairing arrived without the QR secret, so only the Mac's user can vouch for it.
    case pairingNeedsApproval(sessionID: UUID, clientName: String)
    case pairingCompleted(sessionID: UUID, clientName: String, accepted: Bool)
    /// The session holding the prompt ended before an answer.
    case pairingAbandoned(sessionID: UUID)

    case failed(String)
}

/// A device connected to this Mac right now.
struct ConnectedClient: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let since: Date
    let viaRelay: Bool

    /// Elapsed time since this device attached, for both the window and the menu bar.
    func elapsedDescription(now: Date = Date()) -> String {
        Duration.seconds(max(0, now.timeIntervalSince(since)))
            .formatted(.time(pattern: .hourMinuteSecond))
    }
}

struct PairingPrompt: Sendable, Equatable {
    let sessionID: UUID
    let clientName: String
    let code: String
    let secret: Data
    var isRemote = false
    var needsApproval = false
}

struct PairingOutcome: Sendable, Equatable {
    let clientName: String
    let accepted: Bool
}
