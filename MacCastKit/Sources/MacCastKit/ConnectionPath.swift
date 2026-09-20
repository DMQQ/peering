import Foundation

/// Which way one session's control connection is being carried.
///
/// **Declared here and merely named in the app.** It is storage policy rather than app state —
/// three cases, the token each one is printed as, and the question each answers about the
/// allowance — and all of it can be checked without an app bundle, which is why it lives where
/// `swift test` can reach it. The same reasoning as ``StreamQuality``.
///
/// Per session and not per app, which is the point of it being a type at all: one Mac can be on
/// this network while another is on the other side of the country, and the picture ceiling, the
/// record and the allowance all differ between them.
public enum ConnectionPath: String, Sendable, CaseIterable {
    case lan = "LAN"
    case relay = "RELAY"
    case direct = "DIRECT"

    /// The same fact in the spelling a finished record keeps.
    ///
    /// **A mapping rather than a shared raw value**, because the two are read differently on
    /// purpose: this one is shouted at a diagnostics panel, and the record's is set in a column
    /// beside a date. A single enum serving both would have to be named for one of them.
    public var recordPath: ClientSessionRecord.Path {
        switch self {
        case .lan: return .lan
        case .relay: return .relay
        case .direct: return .direct
        }
    }

    /// The record's spelling for a session that may not have one.
    ///
    /// **A session with no path is filed as `lan`, and that is a decision rather than a default.**
    /// The relay meters by how long it splices a connection, so a session the app cannot say was
    /// relayed must not be counted as one — filing it as `.relay` would spend the user's allowance
    /// on their behalf. It is the same answer ``ClientSessionRecord/Path/lan`` gives a session that
    /// ended before the handshake, and the same one the meter has always given it.
    public static func recordPath(of path: ConnectionPath?) -> ClientSessionRecord.Path {
        path?.recordPath ?? .lan
    }
}
