import Foundation

/// Where a phone is from the Mac's side: whether anything it is shown in-app is being seen.
public enum PhonePresence: Sendable, Equatable {
    /// No control connection.
    case gone
    /// Connected and drawing, so the app shows what the Mac would push.
    case foreground
    /// Connected but every connection said it left the foreground, so iOS may freeze it.
    case background
}

/// Who gets a push from the Mac.
public enum PushPolicy {
    /// A phone with a token is pushed to unless it is connected and in the foreground, where the app already shows it and a banner would be a duplicate.
    public static func shouldPush(presence: PhonePresence, hasToken: Bool) -> Bool {
        guard hasToken else { return false }
        return presence != .foreground
    }
}

/// The connections each phone has, and which of them left the foreground.
///
/// A phone can hold two connections at once (a LAN one and a relayed one racing), so it counts as foreground while any of them is.
public struct PhonePresenceBook: Sendable, Equatable {
    private var backgroundBySession: [String: [UUID: Bool]] = [:]

    public init() {}

    public mutating func connected(clientID: String, session: UUID) {
        backgroundBySession[clientID, default: [:]][session] = false
    }

    public mutating func backgroundChanged(clientID: String, session: UUID, background: Bool) {
        guard backgroundBySession[clientID]?[session] != nil else { return }
        backgroundBySession[clientID]?[session] = background
    }

    public mutating func disconnected(clientID: String, session: UUID) {
        backgroundBySession[clientID]?[session] = nil
        if backgroundBySession[clientID]?.isEmpty == true { backgroundBySession[clientID] = nil }
    }

    public func presence(of clientID: String) -> PhonePresence {
        guard let sessions = backgroundBySession[clientID], !sessions.isEmpty else { return .gone }
        return sessions.values.contains(false) ? .foreground : .background
    }
}
