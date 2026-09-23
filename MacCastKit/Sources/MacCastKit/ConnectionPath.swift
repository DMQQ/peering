import Foundation

/// Which way one session's control connection is being carried.
///
/// Per session and not per app: one Mac can be on this network while another is on the other
/// side of the country, and the picture ceiling, the record and the allowance all differ between
/// them.
public enum ConnectionPath: String, Sendable, CaseIterable {
    case lan = "LAN"
    case relay = "RELAY"
    case direct = "DIRECT"

    /// The same fact in the spelling a finished record keeps.
    ///
    /// A mapping rather than a shared raw value: the two are read differently on purpose.
    public var recordPath: ClientSessionRecord.Path {
        switch self {
        case .lan: return .lan
        case .relay: return .relay
        case .direct: return .direct
        }
    }

    /// The record's spelling for a session that may not have one.
    ///
    /// A session with no path is filed as `lan`: the relay meters by how long it splices a
    /// connection, so a session the app cannot say was relayed must not be counted as one.
    public static func recordPath(of path: ConnectionPath?) -> ClientSessionRecord.Path {
        path?.recordPath ?? .lan
    }
}
