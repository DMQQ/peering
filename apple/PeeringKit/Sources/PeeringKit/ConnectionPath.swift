import Foundation

public enum ConnectionPath: String, Sendable, CaseIterable {
    case lan = "LAN"
    case relay = "RELAY"
    case direct = "DIRECT"

    public var recordPath: ClientSessionRecord.Path {
        switch self {
        case .lan: return .lan
        case .relay: return .relay
        case .direct: return .direct
        }
    }

    /// The record's spelling for a session that may not have one.
    public static func recordPath(of path: ConnectionPath?) -> ClientSessionRecord.Path {
        path?.recordPath ?? .lan
    }
}
