import Foundation

/// One phone drives a Mac at a time. A second device is turned away while the first is present, and takes over from one that has gone quiet.
public enum SingleDevicePolicy {
    /// Phones ping every second, so this much silence is a phone that left without saying so, not one that is idle.
    public static let staleAfter: TimeInterval = 20

    public struct Peer: Equatable, Sendable {
        public let clientID: String
        public let silence: TimeInterval

        public init(clientID: String, silence: TimeInterval) {
            self.clientID = clientID
            self.silence = silence
        }
    }

    public enum Decision: Equatable, Sendable {
        case admit(evicting: [String])
        case refuse
    }

    /// - Parameter others: the authorized sessions of devices other than the newcomer.
    public static func decide(newcomer: String, others: [Peer]) -> Decision {
        let rivals = others.filter { $0.clientID != newcomer }
        if rivals.contains(where: { $0.silence < staleAfter }) { return .refuse }
        return .admit(evicting: Array(Set(rivals.map(\.clientID))).sorted())
    }
}
