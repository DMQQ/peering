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

    /// Whether the picture took a path the two ends opened for themselves.
    ///
    /// **A field of its own, and deliberately not a ``Path`` case.** The relay meters by how long
    /// it splices a session, whether or not the picture went around it, so a session that punched
    /// is still a session the relay is charging for. Moving it onto ``path`` would take it off
    /// `.relay`, and `relaySecondsUsedThisPeriod` would stop counting a session that is still
    /// spending the allowance. The two facts look like one and are not.
    ///
    /// It is here at all because "did punching work, and how often" has been an opinion since the
    /// feature shipped, and a second relay region is supposed to be decided on the number rather
    /// than on the opinion. Defaulted, so a record written before this existed decodes as "did not
    /// punch", which is what the app believed at the time.
    public var usedDirectPath: Bool = false

    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    public init(
        id: UUID,
        hostID: String?,
        hostName: String,
        startedAt: Date,
        endedAt: Date,
        path: Path,
        videoBytesReceived: Int64,
        logs: [String],
        usedDirectPath: Bool = false
    ) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.path = path
        self.videoBytesReceived = videoBytesReceived
        self.logs = logs
        self.usedDirectPath = usedDirectPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, hostID, hostName, startedAt, endedAt, path, videoBytesReceived, logs, usedDirectPath
    }

    /// Written out rather than synthesized, for one field.
    ///
    /// **A non-optional property with a default is still required by the synthesized decoder.**
    /// `usedDirectPath` is a field this type grew after records already existed, so a history
    /// written by an earlier build has no key for it and decoding throws `keyNotFound`. That would
    /// not be a visible failure: ``SessionHistoryStore/load()`` reads a decode failure as "nothing
    /// was stored", so the whole thirty-session history would quietly empty itself on the first
    /// launch after an update. Two tests in `MacCastPolicyTests` hold this down, one decoding a
    /// record written without the key.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        hostID = try values.decodeIfPresent(String.self, forKey: .hostID)
        hostName = try values.decode(String.self, forKey: .hostName)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decode(Date.self, forKey: .endedAt)
        path = try values.decode(Path.self, forKey: .path)
        videoBytesReceived = try values.decode(Int64.self, forKey: .videoBytesReceived)
        logs = try values.decode([String].self, forKey: .logs)
        // Absent is "did not punch", which is what the app believed before it could tell.
        usedDirectPath = try values.decodeIfPresent(Bool.self, forKey: .usedDirectPath) ?? false
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
