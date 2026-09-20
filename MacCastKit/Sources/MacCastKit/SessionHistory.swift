import Foundation

/// One completed connection, kept on this iPhone so Activity can explain what happened later.
public struct ClientSessionRecord: Codable, Identifiable, Equatable {
    public enum Path: String, Codable {
        case lan = "LAN"
        case relay = "Relay"
        case direct = "Direct"
    }

    public let id: UUID
    public let hostID: String?
    public let hostName: String
    public let startedAt: Date
    public let endedAt: Date
    public let path: Path
    public let videoBytesReceived: Int64
    public let logs: [String]

    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    public init(
        id: UUID,
        hostID: String?,
        hostName: String,
        startedAt: Date,
        endedAt: Date,
        path: Path,
        videoBytesReceived: Int64,
        logs: [String]
    ) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.path = path
        self.videoBytesReceived = videoBytesReceived
        self.logs = logs
    }
}

/// Relay time, spelled the way the app says it.
///
/// One spelling for the two screens that print it — the meter in the Sessions tab and the sentence
/// at the top of the paywall. "2h 41m left" on the card and "161 minutes left" on the sheet are the
/// same number disagreeing with itself, which is the drift the shared things in this app exist to
/// prevent; and the two are read within seconds of each other by anyone who taps through.
public enum RelayTime {
    /// A duration as hours and minutes, minutes and seconds, or seconds — whichever reads.
    ///
    /// The hours form drops the seconds deliberately. Past an hour they are noise, and a figure that
    /// ticks is one the eye goes back to; "2h 41m" is a level, and a level is what a reader deciding
    /// whether to stay connected needs. Below an hour they are the whole of the useful figure,
    /// because that is the range in which the session is about to be cut off rather than merely
    /// running long.
    public static func label(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(total % 60)s"
        }
        return "\(total)s"
    }
}

public enum SessionHistoryStore {
    private static let key = "Peering.sessionHistory"
    private static let limit = 30

    public static func load() -> [ClientSessionRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ClientSessionRecord].self, from: data)) ?? []
    }

    public static func save(_ records: [ClientSessionRecord]) {
        let kept = Array(records.prefix(limit))
        guard let data = try? JSONEncoder().encode(kept) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
