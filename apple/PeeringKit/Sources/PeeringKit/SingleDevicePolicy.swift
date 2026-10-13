import Foundation

/// One phone drives a Mac at a time. A second device is turned away while the first is present, and takes over from one that has gone quiet.
public enum SingleDevicePolicy {
    /// Phones ping every second, so this much silence is a phone that left without saying so, not one that is idle.
    public static let staleAfter: TimeInterval = 20

    /// A phone that said it left the foreground is frozen by iOS and sends nothing, so it is given the same grace as the reaper gives it before another device may displace it.
    public static let backgroundedStaleAfter: TimeInterval = 180

    public struct Peer: Equatable, Sendable {
        public let clientID: String
        public let silence: TimeInterval
        public let inBackground: Bool

        public init(clientID: String, silence: TimeInterval, inBackground: Bool = false) {
            self.clientID = clientID
            self.silence = silence
            self.inBackground = inBackground
        }

        var isStale: Bool { silence >= (inBackground ? backgroundedStaleAfter : staleAfter) }
    }

    public enum Decision: Equatable, Sendable {
        case admit(evicting: [String])
        case refuse
    }

    /// Who may be displaced is decided here; displacing them is the caller's job, and only once the newcomer is authorised.
    /// - Parameters:
    ///   - others: the authorized sessions of devices other than the newcomer.
    ///   - takesOver: the newcomer asked to displace a present phone, and has proved who it is by the key the Mac pinned for it.
    public static func decide(newcomer: String, others: [Peer], takesOver: Bool = false) -> Decision {
        let rivals = others.filter { $0.clientID != newcomer }
        if !takesOver, rivals.contains(where: { !$0.isStale }) { return .refuse }
        return .admit(evicting: Array(Set(rivals.map(\.clientID))).sorted())
    }
}
